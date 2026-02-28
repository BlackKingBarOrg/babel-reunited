import { getOwner } from "@ember/owner";
import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import { publishToMessageBus } from "discourse/tests/helpers/qunit-helpers";
import LanguageTabsConnector from "discourse/plugins/babel-reunited/discourse/connectors/before-post-article/language-tabs";

function createPost(overrides = {}) {
  return Object.assign(
    {
      id: 1,
      cooked: "<p>Original cooked content</p>",
      raw: "Original raw content",
      post_translations: [
        {
          post_translation: {
            language: "en",
            status: "completed",
            translated_content: "<p>English translation</p>",
          },
        },
        {
          post_translation: {
            language: "zh-cn",
            status: "completed",
            translated_content: "<p>中文翻译</p>",
          },
        },
        {
          post_translation: {
            language: "es",
            status: "translating",
            translated_content: null,
          },
        },
      ],
    },
    overrides
  );
}

module(
  "Discourse Babel Reunited | Integration | Component | language-tabs",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders Original button and 3 language buttons", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs button").exists({ count: 4 });
    });

    test("default selection is original, displaying post.cooked", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("clicking completed language shows translated content", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      await click(".ai-language-tabs button:nth-child(2)");

      assert.dom(".cooked").hasText("English translation");
    });

    test("clicking Original restores post.cooked content", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      await click(".ai-language-tabs button:nth-child(2)");
      assert.dom(".cooked").hasText("English translation");

      await click(".ai-language-tabs button:first-child");
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("clicking uncompleted language falls back to original", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      // es has status "translating" (not completed)
      await click(".ai-language-tabs button:nth-child(4)");

      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("Tripwire: currentContent in original mode returns post.cooked not post.raw", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".cooked").hasText("Original cooked content");
      assert.dom(".cooked").doesNotIncludeText("Original raw content");
    });

    test("auto-selects preferred language when translation is completed", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".cooked").hasText("中文翻译");
    });

    test("shows disabled text when preferred_language_enabled is false", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language_enabled", false);

      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs").doesNotExist();
    });

    test("shows spinner icon for translating status", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs .d-icon-spinner").exists();
    });

    test("MessageBus update refreshes translation data and UI", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert
        .dom(".ai-language-tabs .d-icon-spinner")
        .exists("spinner before update");

      await publishToMessageBus("/post-translations/1", {
        status: "completed",
        language: "es",
        translation: {
          language: "es",
          status: "completed",
          translated_content: "<p>Traducción en español</p>",
        },
      });

      assert
        .dom(".ai-language-tabs .d-icon-spinner")
        .doesNotExist("spinner gone after update");

      await click(".ai-language-tabs button:nth-child(4)");
      assert.dom(".cooked").hasText("Traducción en español");
    });
  }
);
