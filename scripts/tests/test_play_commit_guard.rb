# frozen_string_literal: true

# Offline transport checks. --installed also intercepts the real local Google gem
# before it executes a command, without constructing any authentication client.
require 'json'
require 'rubygems'

installed = ARGV.delete('--installed')
if installed
  gem 'fastlane', '>= 0.a'
  require 'google/apis/androidpublisher_v3'
else
  module Google
    module Apis
      class ClientError < StandardError
        attr_reader :body
        def initialize(message, body: nil, **_options)
          super(message)
          @body = body
        end
      end
    end
  end
end
require_relative '../play_commit_guard'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

class StubService
  attr_accessor :reply_error
  attr_reader :attempts
  def initialize
    @attempts = []
  end
  def commit_edit(package, edit, changes_in_review_behavior: nil, changes_not_sent_for_review: nil)
    @attempts << { package: package, edit: edit, review: changes_in_review_behavior, deferred: changes_not_sent_for_review }
    raise reply_error if reply_error
    { id: edit }
  end
end

PlayOnConRelease.install!(StubService)
PlayOnConRelease.install!(StubService) # Repeat installation must be harmless.
service = StubService.new
[nil, false, true].each do |deferred|
  service.commit_edit('com.fuller.playoncon', 'fixture', changes_not_sent_for_review: deferred)
end
assert(service.attempts.all? { |attempt| attempt[:review] == 'ERROR_IF_IN_REVIEW' }, 'every initial and alternate commit must include the guard')
assert(service.attempts.map { |attempt| attempt[:deferred] } == [nil, false, true], 'preserve the other supply commit flags')

begin
  service.commit_edit('com.fuller.playoncon', 'fixture', changes_in_review_behavior: 'CANCEL_IN_REVIEW_AND_SUBMIT')
  raise 'FAIL: unsafe override was accepted'
rescue PlayOnConRelease::UnsupportedClientError
  assert(service.attempts.length == 3, 'unsafe override must never reach transport')
end

class UnsupportedService
  def commit_edit(_package, _edit, **_options)
    raise 'FAIL: unsupported transport was called'
  end
end
begin
  PlayOnConRelease.install!(UnsupportedService)
  raise 'FAIL: a client without the explicit API parameter was accepted'
rescue PlayOnConRelease::UnsupportedClientError
  assert(!UnsupportedService.ancestors.include?(PlayOnConRelease::CommitGuard), 'unsupported client must fail before installing or uploading')
end

failure = JSON.generate(error: { message: 'fixture-secret-must-not-be-printed', details: [{
  '@type' => 'type.googleapis.com/google.rpc.ErrorInfo',
  'domain' => 'googleapis.com', 'reason' => 'CHANGES_ALREADY_IN_REVIEW'
}] })
rejected = StubService.new
rejected.reply_error = Google::Apis::ClientError.new('fixture response', body: failure)
fallback = false
begin
  rejected.commit_edit('com.fuller.playoncon', 'fixture', changes_not_sent_for_review: false)
rescue Google::Apis::ClientError
  fallback = true # This is the exception fastlane's fallback rescue handles.
  rejected.commit_edit('com.fuller.playoncon', 'fixture')
rescue PlayOnConRelease::ExistingReviewError => error
  assert(error.message.include?('existing review was preserved'), 'report the concrete review blocker')
  assert(!error.message.include?('fixture-secret'), 'never print a Google response body')
  assert(error.cause.nil?, 'never attach the raw review response as an exception cause')
end
assert(!fallback && rejected.attempts.length == 1, 'review rejection must bypass fastlane fallback and never retry')

if installed
  PlayOnConRelease.install!
  actual = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
  commands = []
  # Stub the last transport step before credentials or HTTP are consulted.
  actual.define_singleton_method(:execute_or_queue_command) do |command, &_block|
    commands << command
    { id: 'fixture' }
  end
  [nil, false, true].each do |deferred|
    actual.commit_edit('com.fuller.playoncon', 'fixture', changes_not_sent_for_review: deferred)
  end
  assert(commands.length == 3, 'the actual installed gem must reach only the stub transport')
  assert(commands.all? { |command| command.query['changesInReviewBehavior'] == 'ERROR_IF_IN_REVIEW' }, 'actual gem command must carry the Google HTTP query parameter')
  assert(commands.map { |command| command.query['changesNotSentForReview'] } == [nil, false, true], 'actual gem must preserve every alternate flag')

  # Exercise the installed supply rescue logic with its authentication constructor
  # bypassed and the Google command execution stubbed above.
  require 'fastlane'
  require 'supply'
  Supply.config = { changes_not_sent_for_review: false, rescue_changes_not_sent_for_review: true }
  supply = Supply::Client.allocate
  supply.client = actual
  supply.current_edit = Struct.new(:id).new('fixture')
  supply.current_package_name = 'com.fuller.playoncon'
  commands.clear
  actual.define_singleton_method(:execute_or_queue_command) do |command, &_block|
    commands << command
    raise Google::Apis::ClientError.new('fixture review rejection', status_code: 400, body: failure)
  end
  begin
    supply.commit_current_edit!
    raise 'FAIL: actual supply accepted a review rejection'
  rescue PlayOnConRelease::ExistingReviewError
    assert(commands.length == 1, 'actual supply must not retry an existing-review rejection')
    assert(supply.current_edit.id == 'fixture', 'actual supply must preserve edit state after rejection')
  end

  # An ordinary supply fallback may retry a different deferred-review flag, but
  # the transport guard must still reach Google's query on every attempt.
  commands.clear
  fallback_error = JSON.generate(error: { message: 'The query parameter changesNotSentForReview must not be set' })
  actual.define_singleton_method(:execute_or_queue_command) do |command, &_block|
    commands << command
    if commands.length == 1
      raise Google::Apis::ClientError.new('fixture alternate flag', status_code: 400, body: fallback_error)
    end
    { id: 'fixture' }
  end
  supply.commit_current_edit!
  assert(commands.length == 2, 'exercise the actual supply alternate commit path')
  assert(commands.all? { |command| command.query['changesInReviewBehavior'] == 'ERROR_IF_IN_REVIEW' }, 'actual supply fallback must never drop the review guard')
  puts 'Installed Google Play client transport checks passed without credentials or HTTP.'
end
puts 'Play commit guard offline checks passed.'
