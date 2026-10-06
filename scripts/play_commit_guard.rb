# frozen_string_literal: true

# Guard the Google transport, including fastlane's alternate commit paths.
# https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit
require 'json'

module PlayOnConRelease
  class UnsupportedClientError < StandardError; end
  class ExistingReviewError < StandardError; end

  def self.review_blocked?(error)
    failure = JSON.parse(error.body.to_s)
    details = failure.is_a?(Hash) && failure.dig('error', 'details')
    details.is_a?(Array) && details.any? do |detail|
      detail.is_a?(Hash) &&
        detail['@type'] == 'type.googleapis.com/google.rpc.ErrorInfo' &&
        detail['domain'] == 'googleapis.com' &&
        detail['reason'] == 'CHANGES_ALREADY_IN_REVIEW'
    end
  rescue JSON::ParserError, TypeError
    false
  end

  module CommitGuard
    def commit_edit(package_name, edit_id, **options, &block)
      requested = options[:changes_in_review_behavior]
      if requested && requested != 'ERROR_IF_IN_REVIEW'
        raise UnsupportedClientError, 'Refusing an override that could cancel an existing Google Play review.'
      end

      super(package_name, edit_id, **options.merge(changes_in_review_behavior: 'ERROR_IF_IN_REVIEW'), &block)
    rescue Google::Apis::ClientError => error
      # A separate error class bypasses supply's ClientError fallback retries.
      # No raw Google response body is printed or attached to this error.
      if PlayOnConRelease.review_blocked?(error)
        raise ExistingReviewError,
              'Google Play already has changes in review. The existing review was preserved; wait for it to finish before retrying this upload.',
              cause: nil
      end
      raise
    end
  end

  def self.install!(service = nil)
    unless service
      require 'google/apis/androidpublisher_v3'
      service = Google::Apis::AndroidpublisherV3::AndroidPublisherService
    end
    return true if service.ancestors.include?(CommitGuard)

    supported = service.instance_method(:commit_edit).parameters.any? do |kind, name|
      [:key, :keyreq].include?(kind) && name == :changes_in_review_behavior
    end
    unless supported
      raise UnsupportedClientError,
            'The installed Google Play client cannot preserve existing reviews. Upload stopped before fastlane ran; update the client explicitly before retrying.'
    end
    service.prepend(CommitGuard)
    true
  end
end
