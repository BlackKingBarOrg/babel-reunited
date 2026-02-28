# frozen_string_literal: true

RSpec.describe BabelReunited do
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    SiteSetting.babel_reunited_auto_translate_languages = "zh-cn,en,es"
    SiteSetting.babel_reunited_translate_title = true
    Jobs.run_later!
  end

  describe "post_created event" do
    it "enqueues translation jobs for auto_translate_languages" do
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      %w[zh-cn en es].each do |lang|
        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::TranslatePostJob,
            args: {
              post_id: new_post.id,
              target_language: lang,
            },
          ),
        ).to be true
      end
    end

    it "pre-creates translation records with translating status" do
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      %w[zh-cn en es].each do |lang|
        translation = BabelReunited::PostTranslation.find_translation(new_post.id, lang)
        expect(translation).to be_present
        expect(translation.status).to eq("translating")
      end
    end

    it "does nothing when auto_translate_languages is blank" do
      SiteSetting.babel_reunited_auto_translate_languages = ""
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      expect(BabelReunited::PostTranslation.where(post_id: new_post.id).count).to eq(0)
    end

    it "does nothing when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      expect(BabelReunited::PostTranslation.where(post_id: new_post.id).count).to eq(0)
    end
  end

  describe "post_edited event" do
    it "does not trigger when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "de",
          },
        ),
      ).to be false
    end

    it "only re-translates existing languages when no auto_translate_languages" do
      SiteSetting.babel_reunited_auto_translate_languages = ""
      Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "de",
            force_update: true,
          },
        ),
      ).to be true

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "zh-cn",
          },
        ),
      ).to be false
    end

    it "deduplicates existing translations and auto_translate_languages" do
      Fabricate(:post_translation, post: post_record, language: "es")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      jobs =
        Jobs::BabelReunited::TranslatePostJob.jobs.select do |j|
          j["args"].first["post_id"] == post_record.id && j["args"].first["target_language"] == "es"
        end

      expect(jobs.length).to eq(1)
    end

    it "re-translates existing languages with force_update" do
      Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "de",
            force_update: true,
          },
        ),
      ).to be true
    end

    it "includes auto_translate_languages in re-translation" do
      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      %w[zh-cn en es].each do |lang|
        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::TranslatePostJob,
            args: {
              post_id: post_record.id,
              target_language: lang,
              force_update: true,
            },
          ),
        ).to be true
      end
    end
  end

  describe "user_logged_in event" do
    it "publishes MessageBus prompt for users without preference" do
      messages =
        MessageBus.track_publish("/language-preference-prompt/#{user.id}") do
          DiscourseEvent.trigger(:user_logged_in, user)
        end

      expect(messages.length).to eq(1)
      expect(messages.first.data[:user_id]).to eq(user.id)
    end

    it "does not publish for users with existing preference" do
      Fabricate(:user_preferred_language, user: user, language: "es")

      messages =
        MessageBus.track_publish("/language-preference-prompt/#{user.id}") do
          DiscourseEvent.trigger(:user_logged_in, user)
        end

      expect(messages).to be_empty
    end

    it "does not publish when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false

      messages =
        MessageBus.track_publish("/language-preference-prompt/#{user.id}") do
          DiscourseEvent.trigger(:user_logged_in, user)
        end

      expect(messages).to be_empty
    end
  end

  describe "PostSerializer extensions" do
    let(:guardian) { Guardian.new(user) }

    def serialize_post(a_post)
      PostSerializer.new(a_post, scope: guardian, root: false).as_json
    end

    it "includes available_translations" do
      Fabricate(:post_translation, post: post_record, language: "es")
      json = serialize_post(post_record)
      expect(json[:available_translations]).to include("es")
    end

    it "includes post_translations" do
      Fabricate(:post_translation, post: post_record, language: "es")
      json = serialize_post(post_record)
      expect(json[:post_translations]).to be_present
    end

    it "includes show_translation_widget" do
      json = serialize_post(post_record)
      expect(json).to have_key(:show_translation_widget)
    end

    it "includes show_translation_button" do
      json = serialize_post(post_record)
      expect(json[:show_translation_button]).to be true
    end
  end

  describe "CurrentUserSerializer extensions" do
    def serialize_current_user(a_user)
      CurrentUserSerializer.new(a_user, scope: Guardian.new(a_user), root: false).as_json
    end

    it "includes preferred_language" do
      Fabricate(:user_preferred_language, user: user, language: "es")
      json = serialize_current_user(user)
      expect(json[:preferred_language]).to eq("es")
    end

    it "returns nil preferred_language when not set" do
      json = serialize_current_user(user)
      expect(json[:preferred_language]).to be_nil
    end

    it "includes preferred_language_enabled" do
      Fabricate(:user_preferred_language, user: user, language: "es", enabled: true)
      json = serialize_current_user(user)
      expect(json[:preferred_language_enabled]).to be true
    end
  end

  describe "translated_title serializers" do
    let(:guardian) { Guardian.new(user) }

    before do
      Fabricate(:user_preferred_language, user: user, language: "es", enabled: true)
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        translated_title: "Titulo traducido",
        status: "completed",
      )
    end

    it "includes translated_title in topic_view" do
      topic_view = TopicView.new(topic.id, user)
      json = TopicViewSerializer.new(topic_view, scope: guardian, root: false).as_json
      expect(json[:translated_title]).to eq("Titulo traducido")
    end

    it "includes translated_title in listable_topic" do
      json = ListableTopicSerializer.new(topic, scope: guardian, root: false).as_json
      expect(json[:translated_title]).to eq("Titulo traducido")
    end

    it "includes translated_title in topic_list_item" do
      json = TopicListItemSerializer.new(topic, scope: guardian, root: false).as_json
      expect(json[:translated_title]).to eq("Titulo traducido")
    end
  end

  describe "preload hooks" do
    before do
      Fabricate(:user_preferred_language, user: user, language: "es", enabled: true)
      topic.allowed_user_ids = [user.id]
      topic.update!(first_post: post_record)
    end

    it "does not preload when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      translation = Fabricate(:post_translation, post: post_record, language: "es")

      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to be_nil
    end

    it "does not preload when user has no preferred language" do
      BabelReunited::UserPreferredLanguage.where(user: user).destroy_all
      user.reload

      translation = Fabricate(:post_translation, post: post_record, language: "es")
      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to be_nil
    end

    it "preloads translations for topic view" do
      translation = Fabricate(:post_translation, post: post_record, language: "es")

      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to eq(translation)
    end

    it "preloads translations for topic list" do
      translation = Fabricate(:post_translation, post: post_record, language: "es")
      topic_list = TopicList.new("latest", user, [topic])

      topics = topic_list.topics

      first_post = topics.first.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to eq(translation)
    end
  end

  describe "BabelReunited module methods" do
    describe ".preferred_language_for" do
      it "returns language when user has enabled preference" do
        Fabricate(:user_preferred_language, user: user, language: "es", enabled: true)
        expect(BabelReunited.preferred_language_for(user)).to eq("es")
      end

      it "returns nil when user has disabled preference" do
        Fabricate(:user_preferred_language, user: user, language: "es", enabled: false)
        expect(BabelReunited.preferred_language_for(user)).to be_nil
      end

      it "returns nil for nil user" do
        expect(BabelReunited.preferred_language_for(nil)).to be_nil
      end

      it "returns nil when no preference exists" do
        expect(BabelReunited.preferred_language_for(user)).to be_nil
      end
    end

    describe ".translated_title_for" do
      it "returns translated title when translation is completed" do
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          translated_title: "Titulo traducido",
          status: "completed",
        )

        expect(BabelReunited.translated_title_for(post_record, "es")).to eq("Titulo traducido")
      end

      it "returns nil when translation is not completed" do
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          translated_title: "",
          translated_content: "",
          status: "translating",
        )

        expect(BabelReunited.translated_title_for(post_record, "es")).to be_nil
      end

      it "returns nil for blank post" do
        expect(BabelReunited.translated_title_for(nil, "es")).to be_nil
      end

      it "returns nil for blank language" do
        expect(BabelReunited.translated_title_for(post_record, nil)).to be_nil
      end
    end
  end
end
