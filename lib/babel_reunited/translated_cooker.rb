# frozen_string_literal: true

module BabelReunited
  # Single cooking pipeline for translated raw markdown, shared by the
  # translation job and the recook backfill so the steps can never drift:
  # PrettyText.cook -> Loofah prune -> onebox/image post-processing.
  #
  # Post-processing failures are reported, not raised: callers decide whether
  # the plain-cooked fallback is acceptable (new translations) or the previous
  # content should be kept (backfill).
  class TranslatedCooker
    Result =
      Struct.new(:html, :post_processing_error, keyword_init: true) do
        def post_processed? = post_processing_error.nil?
      end

    def self.call(raw:, post:)
      cooked = PrettyText.cook(raw, topic_id: post.topic_id)
      cooked = Loofah.html5_fragment(cooked).scrub!(:prune).to_s

      begin
        processor = TranslatedCookedPostProcessor.new(cooked, post)
        processor.post_process
        Result.new(html: processor.html.presence || cooked)
      rescue => e
        Result.new(html: cooked, post_processing_error: e)
      end
    end
  end
end
