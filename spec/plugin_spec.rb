# frozen_string_literal: true

RSpec.describe BabelReunited do
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) do
    Fabricate(:post, topic: topic, user: user, post_number: 1)
  end

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
    it "enqueues language detection with fanout instead of direct translation" do
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::DetectPostLanguageJob,
          args: {
            post_id: new_post.id,
            then_fanout: true
          }
        )
      ).to be true
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "creates translating records for auto languages minus the detected one" do
      BabelReunited::LanguageDetectionService
        .any_instance
        .stubs(:call)
        .returns(
          BabelReunited::LanguageDetectionService::Result.new(locale: "en")
        )
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)
      Jobs::BabelReunited::DetectPostLanguageJob.new.execute(
        post_id: new_post.id,
        then_fanout: true
      )

      %w[zh-cn es].each do |lang|
        translation =
          BabelReunited::PostTranslation.find_translation(new_post.id, lang)
        expect(translation).to be_present
        expect(translation.status).to eq("translating")
      end
      expect(
        BabelReunited::PostTranslation.find_translation(new_post.id, "en")
      ).to be_nil
    end

    it "does nothing when auto_translate_languages is blank" do
      SiteSetting.babel_reunited_auto_translate_languages = ""
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      expect(
        BabelReunited::PostTranslation.where(post_id: new_post.id).count
      ).to eq(0)
    end

    it "does nothing when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      new_post = Fabricate(:post, user: user)

      DiscourseEvent.trigger(:post_created, new_post)

      expect(
        BabelReunited::PostTranslation.where(post_id: new_post.id).count
      ).to eq(0)
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
            target_language: "de"
          }
        )
      ).to be false
    end

    it "marks all completed translations stale when no auto_translate_languages" do
      SiteSetting.babel_reunited_auto_translate_languages = ""
      translation =
        Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.status).to eq("stale")
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "deduplicates existing translations and auto_translate_languages" do
      BabelReunited.store_detected_locale(post_record, "ja")
      Fabricate(:post_translation, post: post_record, language: "es")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      jobs =
        Jobs::BabelReunited::TranslatePostJob.jobs.select do |j|
          j["args"].first["post_id"] == post_record.id &&
            j["args"].first["target_language"] == "es"
        end

      expect(jobs.length).to eq(1)
    end

    it "marks lazy-layer translations stale instead of re-translating" do
      translation =
        Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.status).to eq("stale")
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "de",
            force_update: true
          }
        )
      ).to be false
    end

    it "keeps lazy translated_content readable after being marked stale" do
      translation =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "de",
          translated_content: "<p>Altes Inhalt</p>"
        )

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.translated_content).to eq("<p>Altes Inhalt</p>")
    end

    it "does not touch translating or failed lazy translations on edit" do
      translating =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "de",
          status: "translating",
          translated_content: ""
        )
      failed =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "fr",
          status: "failed",
          translated_content: ""
        )

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translating.reload.status).to eq("translating")
      expect(failed.reload.status).to eq("failed")
    end

    it "includes auto_translate_languages in re-translation" do
      BabelReunited.store_detected_locale(post_record, "ja")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      %w[zh-cn en es].each do |lang|
        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::TranslatePostJob,
            args: {
              post_id: post_record.id,
              target_language: lang,
              force_update: true
            }
          )
        ).to be true
      end
    end

    it "routes edits with changed content through re-detection" do
      BabelReunited.store_detected_locale(post_record, "en", raw_sha: "0" * 64)

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

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

    it "invalidates translations of a hidden post without dispatching work" do
      # Invalidation is local bookkeeping: a hidden post whose content changed
      # must not keep serving pre-edit translations once it becomes visible.
      translation =
        Fabricate(:post_translation, post: post_record, language: "de")
      post_record.update!(hidden: true)

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.status).to eq("stale")
      expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "invalidates translations of a deleted post without dispatching work" do
      translation =
        Fabricate(:post_translation, post: post_record, language: "de")
      post_record.trash!

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.status).to eq("stale")
      expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
    end

    it "marks pre-translate-layer translations stale too when content changed" do
      # The post was English (es/zh-cn were its translations) and is rewritten
      # in Spanish. The old es translation is now both outdated and redundant:
      # it must not stay completed and readable as pre-edit content.
      BabelReunited.store_detected_locale(post_record, "en", raw_sha: "0" * 64)
      es = Fabricate(:post_translation, post: post_record, language: "es")
      zh = Fabricate(:post_translation, post: post_record, language: "zh-cn")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(es.reload.status).to eq("stale")
      expect(zh.reload.status).to eq("stale")
      expect(es.translated_content).to be_present
    end

    it "still marks lazy translations stale when routing through re-detection" do
      translation =
        Fabricate(:post_translation, post: post_record, language: "de")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(translation.reload.status).to eq("stale")
      expect(
        job_enqueued?(job: Jobs::BabelReunited::DetectPostLanguageJob, args: {})
      ).to be true
    end

    it "excludes the detected source language from eager re-translation" do
      BabelReunited.store_detected_locale(post_record, "en")
      legacy_copy =
        Fabricate(:post_translation, post: post_record, language: "en")

      revisor = OpenStruct.new(topic_diff: {})
      DiscourseEvent.trigger(:post_edited, post_record, false, revisor)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "en"
          }
        )
      ).to be false
      expect(legacy_copy.reload.status).to eq("stale")

      %w[zh-cn es].each do |lang|
        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::TranslatePostJob,
            args: {
              post_id: post_record.id,
              target_language: lang,
              force_update: true
            }
          )
        ).to be true
      end
    end
  end

  describe "category_created event" do
    fab!(:category_with_definition)

    it "enqueues language detection for the category definition post" do
      first_post = category_with_definition.topic.first_post

      DiscourseEvent.trigger(:category_created, category_with_definition)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::DetectPostLanguageJob,
          args: {
            post_id: first_post.id,
            then_fanout: true
          }
        )
      ).to be true
    end

    it "does nothing when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      first_post = category_with_definition.topic.first_post

      DiscourseEvent.trigger(:category_created, category_with_definition)

      expect(
        BabelReunited::PostTranslation.where(post_id: first_post.id).count
      ).to eq(0)
    end

    it "does not trigger when category is not in enabled_categories" do
      other_category = Fabricate(:category)
      SiteSetting.babel_reunited_enabled_categories = other_category.id.to_s

      first_post = category_with_definition.topic.first_post

      DiscourseEvent.trigger(:category_created, category_with_definition)

      expect(
        BabelReunited::PostTranslation.where(post_id: first_post.id).count
      ).to eq(0)
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

    it "includes lightweight babel_translations_meta without bodies" do
      Fabricate(:post_translation, post: post_record, language: "es")
      json = serialize_post(post_record)

      meta = json[:babel_translations_meta]
      expect(meta.length).to eq(1)
      expect(meta.first[:language]).to eq("es")
      expect(meta.first[:status]).to eq("completed")
      expect(meta.first[:source_language]).to eq("en")
      expect(meta.first).not_to have_key(:translated_content)
    end

    it "does not serialize legacy post_translations and available_translations" do
      Fabricate(:post_translation, post: post_record, language: "es")
      json = serialize_post(post_record)

      expect(json).not_to have_key(:post_translations)
      expect(json).not_to have_key(:available_translations)
    end

    it "includes the full body only for the viewer's preferred language" do
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )
      Fabricate(:post_translation, post: post_record, language: "es")
      Fabricate(:post_translation, post: post_record, language: "de")

      json = serialize_post(post_record)

      preferred = json[:babel_preferred_translation]
      expect(preferred[:language]).to eq("es")
      expect(preferred[:translated_content]).to include("Hola mundo")
      expect(
        json[:babel_translations_meta].map { |t| t[:language] }
      ).to contain_exactly("es", "de")
    end

    it "omits babel_preferred_translation without a preference" do
      Fabricate(:post_translation, post: post_record, language: "es")
      json = serialize_post(post_record)
      expect(json).not_to have_key(:babel_preferred_translation)
    end

    it "includes babel_detected_locale when detected" do
      BabelReunited.store_detected_locale(post_record, "en")
      json = serialize_post(post_record.reload)
      expect(json[:babel_detected_locale]).to eq("en")
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
      CurrentUserSerializer.new(
        a_user,
        scope: Guardian.new(a_user),
        root: false
      ).as_json
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
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )
      json = serialize_current_user(user)
      expect(json[:preferred_language_enabled]).to be true
    end
  end

  describe "translated_title serializers" do
    let(:guardian) { Guardian.new(user) }

    before do
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        translated_title: "Titulo traducido",
        status: "completed"
      )
    end

    it "never serves a title from a translation into the post's own language" do
      # The post was rewritten in Spanish; its old es translation lingers as
      # stale content that nothing will refresh.
      BabelReunited.store_detected_locale(post_record, "es")

      json =
        ListableTopicSerializer.new(topic, scope: guardian, root: false).as_json
      expect(json[:babel_translated_title]).to be_nil
    end

    it "includes babel_translated_title in topic_view" do
      topic_view = TopicView.new(topic.id, user)
      json =
        TopicViewSerializer.new(
          topic_view,
          scope: guardian,
          root: false
        ).as_json
      expect(json[:babel_translated_title]).to eq("Titulo traducido")
    end

    it "includes babel_translated_title in listable_topic" do
      json =
        ListableTopicSerializer.new(topic, scope: guardian, root: false).as_json
      expect(json[:babel_translated_title]).to eq("Titulo traducido")
    end

    it "includes babel_translated_title in topic_list_item" do
      json =
        TopicListItemSerializer.new(topic, scope: guardian, root: false).as_json
      expect(json[:babel_translated_title]).to eq("Titulo traducido")
    end
  end

  describe "preload hooks" do
    before do
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )
      topic.allowed_user_ids = [user.id]
      topic.update!(first_post: post_record)
    end

    it "does not preload when plugin is disabled" do
      SiteSetting.babel_reunited_enabled = false
      translation =
        Fabricate(:post_translation, post: post_record, language: "es")

      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to be_nil
    end

    it "does not preload when user has no preferred language" do
      BabelReunited::UserPreferredLanguage.where(user: user).destroy_all
      user.reload

      translation =
        Fabricate(:post_translation, post: post_record, language: "es")
      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to be_nil
    end

    it "preloads translations for topic view" do
      translation =
        Fabricate(:post_translation, post: post_record, language: "es")

      topic_view = TopicView.new(topic.id, user)

      first_post = topic_view.topic.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to eq(translation)
    end

    it "preloads translations for topic list" do
      translation =
        Fabricate(:post_translation, post: post_record, language: "es")
      topic_list = TopicList.new("latest", user, [topic])

      topics = topic_list.topics

      first_post = topics.first.first_post
      preloaded = BabelReunited.preloaded_post_translation(first_post, "es")
      expect(preloaded).to eq(translation)
    end

    it "preloads meta rows without translation bodies" do
      Fabricate(:post_translation, post: post_record, language: "de")

      topic_view = TopicView.new(topic.id, user)
      preloaded =
        BabelReunited.preloaded_all_translations(topic_view.posts.first)

      expect(preloaded.length).to eq(1)
      expect(preloaded.first.has_attribute?(:translated_content)).to be false
      expect(preloaded.first.language).to eq("de")
    end

    it "preloads preferred-language bodies for every stream post" do
      second_post = Fabricate(:post, topic: topic, user: user)
      translation =
        Fabricate(:post_translation, post: second_post, language: "es")

      topic_view = TopicView.new(topic.id, user)
      stream_post = topic_view.posts.find { |p| p.id == second_post.id }

      expect(BabelReunited.preloaded_post_translation(stream_post, "es")).to eq(
        translation
      )
    end
  end

  describe "category whitelist" do
    fab!(:allowed_category, :category)
    fab!(:blocked_category, :category)

    describe ".translation_enabled_for_category?" do
      it "returns true when setting is blank" do
        SiteSetting.babel_reunited_enabled_categories = ""
        expect(
          BabelReunited.translation_enabled_for_category?(allowed_category.id)
        ).to be true
      end

      it "returns true when category is in the whitelist" do
        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s
        expect(
          BabelReunited.translation_enabled_for_category?(allowed_category.id)
        ).to be true
      end

      it "returns false when category is not in the whitelist" do
        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s
        expect(
          BabelReunited.translation_enabled_for_category?(blocked_category.id)
        ).to be false
      end

      it "returns false when category_id is nil and whitelist is set" do
        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s
        expect(BabelReunited.translation_enabled_for_category?(nil)).to be false
      end
    end

    describe "post_created event with category whitelist" do
      it "does not enqueue detection for non-whitelisted category" do
        topic_in_blocked =
          Fabricate(:topic, user: user, category: blocked_category)
        new_post = Fabricate(:post, topic: topic_in_blocked, user: user)

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        DiscourseEvent.trigger(:post_created, new_post)

        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::DetectPostLanguageJob,
            args: {
              post_id: new_post.id
            }
          )
        ).to be false
      end

      it "enqueues detection for whitelisted category" do
        topic_in_allowed =
          Fabricate(:topic, user: user, category: allowed_category)
        new_post = Fabricate(:post, topic: topic_in_allowed, user: user)

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        DiscourseEvent.trigger(:post_created, new_post)

        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::DetectPostLanguageJob,
            args: {
              post_id: new_post.id,
              then_fanout: true
            }
          )
        ).to be true
      end
    end

    describe "post_edited event with category whitelist" do
      it "does not enqueue jobs for non-whitelisted category" do
        topic_in_blocked =
          Fabricate(:topic, user: user, category: blocked_category)
        blocked_post = Fabricate(:post, topic: topic_in_blocked, user: user)

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        revisor = OpenStruct.new(topic_diff: {})
        DiscourseEvent.trigger(:post_edited, blocked_post, false, revisor)

        expect(
          job_enqueued?(
            job: Jobs::BabelReunited::TranslatePostJob,
            args: {
              post_id: blocked_post.id,
              target_language: "zh-cn"
            }
          )
        ).to be false
      end
    end

    describe "show_translation_button with category whitelist" do
      let(:guardian) { Guardian.new(user) }

      it "returns false for non-whitelisted category" do
        topic_in_blocked =
          Fabricate(:topic, user: user, category: blocked_category)
        blocked_post = Fabricate(:post, topic: topic_in_blocked, user: user)

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        json =
          PostSerializer.new(blocked_post, scope: guardian, root: false).as_json
        expect(json[:show_translation_button]).to be false
      end

      it "returns true for whitelisted category" do
        topic_in_allowed =
          Fabricate(:topic, user: user, category: allowed_category)
        allowed_post = Fabricate(:post, topic: topic_in_allowed, user: user)

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        json =
          PostSerializer.new(allowed_post, scope: guardian, root: false).as_json
        expect(json[:show_translation_button]).to be true
      end
    end

    describe "babel_translated_title with category whitelist" do
      let(:guardian) { Guardian.new(user) }

      before do
        Fabricate(
          :user_preferred_language,
          user: user,
          language: "es",
          enabled: true
        )
      end

      it "returns nil for non-whitelisted category in topic_view" do
        topic_in_blocked =
          Fabricate(:topic, user: user, category: blocked_category)
        blocked_post =
          Fabricate(:post, topic: topic_in_blocked, user: user, post_number: 1)
        topic_in_blocked.update!(first_post: blocked_post)
        Fabricate(
          :post_translation,
          post: blocked_post,
          language: "es",
          translated_title: "Titulo bloqueado",
          status: "completed"
        )

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        topic_view = TopicView.new(topic_in_blocked.id, user)
        json =
          TopicViewSerializer.new(
            topic_view,
            scope: guardian,
            root: false
          ).as_json
        expect(json[:babel_translated_title]).to be_nil
      end

      it "returns nil for non-whitelisted category in topic_list_item" do
        topic_in_blocked =
          Fabricate(:topic, user: user, category: blocked_category)
        blocked_post =
          Fabricate(:post, topic: topic_in_blocked, user: user, post_number: 1)
        topic_in_blocked.update!(first_post: blocked_post)
        Fabricate(
          :post_translation,
          post: blocked_post,
          language: "es",
          translated_title: "Titulo bloqueado",
          status: "completed"
        )

        SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

        json =
          TopicListItemSerializer.new(
            topic_in_blocked,
            scope: guardian,
            root: false
          ).as_json
        expect(json[:babel_translated_title]).to be_nil
      end
    end
  end

  describe "BabelReunited module methods" do
    describe ".preferred_language_for" do
      it "returns language when user has enabled preference" do
        Fabricate(
          :user_preferred_language,
          user: user,
          language: "es",
          enabled: true
        )
        expect(BabelReunited.preferred_language_for(user)).to eq("es")
      end

      it "returns nil when user has disabled preference" do
        Fabricate(
          :user_preferred_language,
          user: user,
          language: "es",
          enabled: false
        )
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
          status: "completed"
        )

        expect(BabelReunited.translated_title_for(post_record, "es")).to eq(
          "Titulo traducido"
        )
      end

      it "returns nil when translation is translating with no prior title" do
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          translated_title: "",
          translated_content: "",
          status: "translating"
        )

        expect(BabelReunited.translated_title_for(post_record, "es")).to be_nil
      end

      it "returns prior title when re-translating (status=translating with old title)" do
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          translated_title: "Titulo antiguo",
          translated_content: "<p>Old content</p>",
          status: "translating"
        )

        expect(BabelReunited.translated_title_for(post_record, "es")).to eq(
          "Titulo antiguo"
        )
      end

      it "returns nil for failed translations even if an old title is present" do
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          translated_title: "Titulo antiguo",
          translated_content: "<p>Old content</p>",
          status: "failed"
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
