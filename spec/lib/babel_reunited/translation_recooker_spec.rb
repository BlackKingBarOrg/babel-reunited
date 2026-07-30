# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationRecooker do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  def create_translation(
    post: post_record,
    language: "zh-cn",
    raw: "**中文** 内容",
    content: "<p>stale</p>"
  )
    BabelReunited::PostTranslation.create!(
      post_id: post.id,
      language: language,
      status: "completed",
      source_language: "en",
      translated_raw: raw,
      translated_content: content
    )
  end

  def run(**opts)
    described_class.new(dry_run: false, **opts).run
  end

  describe "live run" do
    it "recooks stale content from translated_raw" do
      translation = create_translation

      stats = run

      expect(stats.processed).to eq(1)
      expect(translation.reload.translated_content).to include(
        "<strong>中文</strong>"
      )
    end

    it "is idempotent across consecutive runs" do
      translation = create_translation

      run
      recooked = translation.reload.translated_content
      stats = run

      expect(stats.processed).to eq(0)
      expect(stats.unchanged).to eq(1)
      expect(translation.reload.translated_content).to eq(recooked)
    end

    it "keeps existing content when post-processing fails" do
      translation = create_translation
      BabelReunited::TranslatedCookedPostProcessor
        .any_instance
        .stubs(:post_process)
        .raises(StandardError.new("onebox timeout"))

      stats = run

      expect(stats.failed).to eq(1)
      expect(stats.processed).to eq(0)
      expect(translation.reload.translated_content).to eq("<p>stale</p>")
    end

    it "skips records whose post is deleted" do
      translation = create_translation
      post_record.trash!

      stats = run

      expect(stats.skipped_deleted).to eq(1)
      expect(translation.reload.translated_content).to eq("<p>stale</p>")
    end

    it "never overwrites a record that changed mid-run" do
      translation = create_translation

      BabelReunited::TranslatedCooker
        .stubs(:call)
        .with do |**|
          # Simulates a translation job finishing while this record was being
          # cooked: the pre-write concurrency check must detect it.
          translation.update_columns(
            translated_raw: "refreshed elsewhere",
            translated_content: "<p>refreshed elsewhere</p>",
            updated_at: 1.minute.from_now
          )
          true
        end
        .returns(
          BabelReunited::TranslatedCooker::Result.new(
            html: "<p>stale recook output</p>"
          )
        )

      stats = run

      expect(stats.skipped_changed).to eq(1)
      expect(stats.processed).to eq(0)
      expect(translation.reload.translated_content).to eq(
        "<p>refreshed elsewhere</p>"
      )
    end
  end

  describe "dry run" do
    it "counts matches without cooking, network access, or writes" do
      translation = create_translation
      BabelReunited::TranslatedCooker.expects(:call).never
      BabelReunited::TranslatedCookedPostProcessor.expects(:new).never

      stats = described_class.new(dry_run: true).run

      expect(stats.matched).to eq(1)
      expect(translation.reload.translated_content).to eq("<p>stale</p>")
    end
  end

  describe "validate mode" do
    it "cooks and reports changes without writing" do
      translation = create_translation

      stats = run(validate: true)

      expect(stats.processed).to eq(1)
      expect(translation.reload.translated_content).to eq("<p>stale</p>")
    end
  end

  describe "scope selection" do
    it "only targets recookable records, complementary to needs_retranslation" do
      recookable = create_translation
      blank_raw = create_translation(language: "es", raw: "   ")
      nil_raw = create_translation(language: "en", raw: nil)
      # BTRIM would miss these: only [[:space:]] classifies them correctly
      whitespace_raw = create_translation(language: "de", raw: " \n\t\r")

      expect(BabelReunited::PostTranslation.recookable).to contain_exactly(
        recookable
      )
      expect(
        BabelReunited::PostTranslation.needs_retranslation
      ).to contain_exactly(blank_raw, nil_raw, whitespace_raw)

      stats = run

      expect(stats.matched).to eq(1)
      expect(stats.processed).to eq(1)
      expect(blank_raw.reload.translated_content).to eq("<p>stale</p>")
      expect(nil_raw.reload.translated_content).to eq("<p>stale</p>")
      expect(whitespace_raw.reload.translated_content).to eq("<p>stale</p>")
    end

    it "honors language, post_id, and limit filters" do
      first = create_translation
      second_post = Fabricate(:post, topic: topic, user: user)
      second = create_translation(post: second_post, language: "es")

      stats = run(language: "es")
      expect(stats.processed).to eq(1)
      expect(second.reload.translated_content).to include("<strong>")
      expect(first.reload.translated_content).to eq("<p>stale</p>")

      stats = run(limit: 0)
      expect(stats.processed).to eq(0)

      stats = run(post_id: post_record.id)
      expect(stats.processed).to eq(1)
      expect(first.reload.translated_content).to include("<strong>")
    end
  end
end
