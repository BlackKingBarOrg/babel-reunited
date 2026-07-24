# frozen_string_literal: true

module BabelReunited
  # Runs the same cooked-HTML post-processing on translated content that core
  # runs on regular posts (CookedPostProcessor) and on localizations
  # (LocalizedCookedPostProcessor): onebox expansion, inline-onebox title
  # resolution, and image handling (lightbox wrappers, size limits).
  # Plain PrettyText.cook alone leaves oneboxes stuck in their "loading"
  # state and images without lightboxes, so translations render differently
  # from the original post.
  class TranslatedCookedPostProcessor
    include ::CookedProcessorMixin

    def initialize(cooked, post, opts = {})
      @post = post
      @opts = opts
      @doc = Loofah.html5_fragment(cooked)
      @cooking_options = (@post.cooking_options || {}).symbolize_keys
      @cooking_options[:topic_id] = @post.topic_id
      @model = @post
      @category_id = @post&.topic&.category_id
      @omit_nofollow = @post.omit_nofollow?
      @size_cache = {}
    end

    def post_process
      post_process_oneboxes
      post_process_images
    end

    def html
      @doc.try(:to_html)
    end
  end
end
