# frozen_string_literal: true

RSpec.describe BabelReunited::TranslatedCooker do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  it "cooks markdown to html" do
    result = described_class.call(raw: "**Bold** text", post: post_record)

    expect(result.post_processed?).to be true
    expect(result.html).to include("<strong>Bold</strong>")
  end

  it "sanitizes unsafe markup" do
    result =
      described_class.call(
        raw: "safe<script>alert('boom')</script> text",
        post: post_record
      )

    expect(result.html).not_to include("<script>")
  end

  it "post-processes images into lightboxes like regular posts" do
    upload = Fabricate(:image_upload, width: 150, height: 150)
    result =
      described_class.call(
        raw: "<img src=\"#{upload.url}\">",
        post: post_record
      )

    expect(result.post_processed?).to be true
    expect(result.html).to include("lightbox-wrapper")
  end

  it "reports post-processing failures and falls back to plain cooked html" do
    BabelReunited::TranslatedCookedPostProcessor
      .any_instance
      .stubs(:post_process)
      .raises(StandardError.new("boom"))

    result = described_class.call(raw: "**Bold** text", post: post_record)

    expect(result.post_processed?).to be false
    expect(result.post_processing_error.message).to eq("boom")
    expect(result.html).to include("<strong>Bold</strong>")
  end
end
