#!/usr/bin/env ruby
# frozen_string_literal: true

# Activate the same installed Ruby gems as fastlane's executable, then guard
# every Google Play commit before entering supply. Never edit installed gems.
require 'rubygems'
Gem.use_gemdeps
require_relative 'play_commit_guard'

begin
  gem 'fastlane', '>= 0.a'
  PlayOnConRelease.install!
rescue LoadError, PlayOnConRelease::UnsupportedClientError
  abort 'Play upload stopped: the installed fastlane/Google Play client cannot enforce the existing-review guard. No upload was attempted.'
end

if ARGV == ['--check-guard']
  puts 'Installed fastlane Google Play commit guard is ready (no store access attempted).'
  exit 0
end

ARGV.unshift('supply')
# activate_bin_path works across older RubyGems too and returns the path to load.
load Gem.activate_bin_path('fastlane', 'fastlane', '>= 0.a')
