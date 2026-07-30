# frozen_string_literal: true

RSpec.describe Jobs::BabelReunited::DetectPostLanguageJob do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_auto_translate_languages = "zh-cn,en,es"
    Discourse.redis.flushdb
    Jobs.run_later!
  end

  def stub_detection_success(locale)
    BabelReunited::LanguageDetectionService
      .any_instance
      .stubs(:call)
      .returns(BabelReunited::LanguageDetectionService::Result.new(locale: locale))
  end

  def stub_detection_failure(error = "boom")
    BabelReunited::LanguageDetectionService
      .any_instance
      .stubs(:call)
      .returns(BabelReunited::LanguageDetectionService::Result.new(error: error))
  end

  it "stores the detected locale on the post" do
    stub_detection_success("en")

    described_class.new.execute(post_id: post_record.id)

    expect(post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]).to eq("en")
  end

  it "does not re-detect when the post already has a locale" do
    BabelReunited.store_detected_locale(post_record, "th")
    BabelReunited::LanguageDetectionService.any_instance.expects(:call).never

    described_class.new.execute(post_id: post_record.id)

    expect(post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]).to eq("th")
  end

  it "fans out to auto languages minus the detected one" do
    stub_detection_success("en")

    described_class.new.execute(post_id: post_record.id, then_fanout: true)

    %w[zh-cn es].each do |lang|
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: lang,
          },
        ),
      ).to be true
      expect(
        BabelReunited::PostTranslation.find_translation(post_record.id, lang)&.status,
      ).to eq("translating")
    end

    expect(
      job_enqueued?(
        job: Jobs::BabelReunited::TranslatePostJob,
        args: {
          post_id: post_record.id,
          target_language: "en",
        },
      ),
    ).to be false
    expect(BabelReunited::PostTranslation.find_translation(post_record.id, "en")).to be_nil
  end

  it "fans out to all auto languages when detection fails" do
    stub_detection_failure

    described_class.new.execute(post_id: post_record.id, then_fanout: true)

    %w[zh-cn en es].each do |lang|
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: lang,
          },
        ),
      ).to be true
    end
    expect(post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]).to be_blank
  end

  it "does not fan out without then_fanout" do
    stub_detection_success("en")

    described_class.new.execute(post_id: post_record.id)

    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end

  it "re-raises RateLimitError for Sidekiq retry" do
    BabelReunited::LanguageDetectionService
      .any_instance
      .stubs(:call)
      .raises(BabelReunited::RateLimitError.new("limited"))

    expect { described_class.new.execute(post_id: post_record.id) }.to raise_error(
      BabelReunited::RateLimitError,
    )
  end
end
