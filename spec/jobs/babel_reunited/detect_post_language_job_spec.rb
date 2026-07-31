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
      .returns(
        BabelReunited::LanguageDetectionService::Result.new(locale: locale)
      )
  end

  def stub_detection_failure(error = "boom")
    BabelReunited::LanguageDetectionService
      .any_instance
      .stubs(:call)
      .returns(
        BabelReunited::LanguageDetectionService::Result.new(error: error)
      )
  end

  it "stores the detected locale and content fingerprint on the post" do
    stub_detection_success("en")

    described_class.new.execute(post_id: post_record.id)

    post_record.reload
    expect(
      post_record.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]
    ).to eq("en")
    expect(post_record.custom_fields[BabelReunited::DETECTED_SHA_FIELD]).to eq(
      BabelReunited.detection_raw_sha(post_record)
    )
  end

  it "does not re-detect when the detection is current" do
    BabelReunited.store_detected_locale(post_record, "th")
    BabelReunited::LanguageDetectionService.any_instance.expects(:call).never

    described_class.new.execute(post_id: post_record.id)

    expect(
      post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]
    ).to eq("th")
  end

  it "re-detects when the content changed since the last detection" do
    BabelReunited.store_detected_locale(post_record, "th", raw_sha: "0" * 64)
    stub_detection_success("en")

    described_class.new.execute(post_id: post_record.id)

    expect(
      post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]
    ).to eq("en")
  end

  it "discards the result and retries when the post changes during detection" do
    detection_result =
      BabelReunited::LanguageDetectionService::Result.new(locale: "en")
    fake_service = Object.new
    target_post = post_record
    fake_service.define_singleton_method(:call) do
      target_post.update_columns(
        raw: "Contenu remplace pendant la detection en cours"
      )
      detection_result
    end
    BabelReunited::LanguageDetectionService.stubs(:new).returns(fake_service)

    described_class.new.execute(post_id: post_record.id, then_fanout: true)

    expect(
      post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]
    ).to be_blank
    expect(
      job_enqueued?(
        job: Jobs::BabelReunited::DetectPostLanguageJob,
        args: {
          post_id: post_record.id,
          then_fanout: true
        }
      )
    ).to be true
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
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
            target_language: lang
          }
        )
      ).to be true
      expect(
        BabelReunited::PostTranslation.find_translation(
          post_record.id,
          lang
        )&.status
      ).to eq("translating")
    end

    expect(
      job_enqueued?(
        job: Jobs::BabelReunited::TranslatePostJob,
        args: {
          post_id: post_record.id,
          target_language: "en"
        }
      )
    ).to be false
    expect(
      BabelReunited::PostTranslation.find_translation(post_record.id, "en")
    ).to be_nil
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
            target_language: lang
          }
        )
      ).to be true
    end
    expect(
      post_record.reload.custom_fields[BabelReunited::DETECTED_LOCALE_FIELD]
    ).to be_blank
  end

  it "ignores a stale detection when the retry fails, fanning out to every language" do
    # The post used to be English; it has since been rewritten and detection
    # cannot confirm the new language.
    BabelReunited.store_detected_locale(post_record, "en", raw_sha: "0" * 64)
    stub_detection_failure

    described_class.new.execute(post_id: post_record.id, then_fanout: true)

    %w[zh-cn en es].each do |lang|
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: lang
          }
        )
      ).to be true
    end
  end

  describe "post guards" do
    it "never sends a hidden post to the provider" do
      post_record.update!(hidden: true)
      BabelReunited::LanguageDetectionService.any_instance.expects(:call).never

      described_class.new.execute(post_id: post_record.id, then_fanout: true)

      expect(
        BabelReunited::PostTranslation.where(post_id: post_record.id)
      ).to be_empty
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "never sends a deleted post to the provider" do
      post_record.trash!
      BabelReunited::LanguageDetectionService.any_instance.expects(:call).never

      described_class.new.execute(post_id: post_record.id, then_fanout: true)

      expect(
        BabelReunited::PostTranslation.where(post_id: post_record.id)
      ).to be_empty
    end

    it "never sends a post from a disabled category to the provider" do
      SiteSetting.babel_reunited_enabled_categories =
        Fabricate(:category).id.to_s
      BabelReunited::LanguageDetectionService.any_instance.expects(:call).never

      described_class.new.execute(post_id: post_record.id, then_fanout: true)

      expect(
        BabelReunited::PostTranslation.where(post_id: post_record.id)
      ).to be_empty
    end
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

    expect {
      described_class.new.execute(post_id: post_record.id)
    }.to raise_error(BabelReunited::RateLimitError)
  end
end
