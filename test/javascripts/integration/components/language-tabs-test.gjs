import { getOwner } from "@ember/owner";
import { click, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
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

      // Button order follows site setting default: en(2), zh-cn(3), es(4)
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

    test("clicking uncompleted language triggers on-demand translation", async function (assert) {
      pretender.post("/babel-reunited/posts/1/translations", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST target_language=${body.get("target_language")}`);
        return response({ status: "queued" });
      });

      this.set(
        "post",
        createPost({
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
                status: "pending",
                translated_content: null,
              },
            },
          ],
        })
      );
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      await click(".ai-language-tabs button:nth-child(4)");

      assert.verifySteps(["POST target_language=es"]);
      assert
        .dom(".ai-language-tabs button:nth-child(4) .spinner.small")
        .exists("shows spinner after triggering translation");
    });

    test("clicking a translating tab does not trigger duplicate request", async function (assert) {
      pretender.post("/babel-reunited/posts/1/translations", () => {
        assert.step("POST called");
        return response({ status: "queued" });
      });

      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      // es already has status "translating" — clicking should not fire AJAX
      await click(".ai-language-tabs button:nth-child(4)");

      assert.verifySteps([]);
    });

    test("translating tab with old content switches and shows the old translation", async function (assert) {
      pretender.post("/babel-reunited/posts/1/translations", () => {
        assert.step("POST called");
        return response({ status: "queued" });
      });

      this.set(
        "post",
        createPost({
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
                status: "translating",
                translated_content: "<p>旧的中文翻译</p>",
              },
            },
            {
              post_translation: {
                language: "es",
                status: "completed",
                translated_content: "<p>Traducción</p>",
              },
            },
          ],
        })
      );
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      // zh-cn is re-translating but has old content — clicking should show old content
      await click(".ai-language-tabs button:nth-child(3)");

      assert.dom(".cooked").hasText("旧的中文翻译");
      assert.verifySteps([]);
    });

    test("on-demand translation auto-switches on MessageBus completion", async function (assert) {
      let resolveRequest;
      pretender.post("/babel-reunited/posts/1/translations", () => {
        return new Promise((resolve) => {
          resolveRequest = resolve;
        });
      });

      this.set(
        "post",
        createPost({
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
                status: "failed",
                translated_content: null,
              },
            },
          ],
        })
      );
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      // Click failed "es" tab to trigger on-demand
      click(".ai-language-tabs button:nth-child(4)");
      await new Promise((resolve) => setTimeout(resolve, 10));

      resolveRequest(response({ status: "queued" }));
      await settled();

      assert.dom(".cooked").hasText("Original cooked content");

      await publishToMessageBus("/post-translations/1", {
        status: "completed",
        language: "es",
        translation: {
          language: "es",
          status: "completed",
          translated_content: "<p>Traducción en español</p>",
        },
      });

      assert.dom(".cooked").hasText("Traducción en español");
    });

    test("on-demand translation reverts optimistic state on error", async function (assert) {
      pretender.post("/babel-reunited/posts/1/translations", () => {
        return response(429, { errors: ["rate limited"] });
      });

      this.set(
        "post",
        createPost({
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
          ],
        })
      );
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      await click(".ai-language-tabs button:nth-child(4)");

      assert
        .dom(".ai-language-tabs button:nth-child(4) .spinner.small")
        .doesNotExist("spinner removed after error");
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

      assert.dom(".ai-language-tabs .spinner.small").exists();
    });

    test("MessageBus update refreshes translation data and UI", async function (assert) {
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert
        .dom(".ai-language-tabs .spinner.small")
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
        .dom(".ai-language-tabs .spinner.small")
        .doesNotExist("spinner gone after update");

      await click(".ai-language-tabs button:nth-child(4)");
      assert.dom(".cooked").hasText("Traducción en español");
    });

    test("hides tabs when category is not in whitelist", async function (assert) {
      this.siteSettings.babel_reunited_enabled_categories = "99";
      this.set("post", createPost({ topic: { category_id: 42 } }));
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs").doesNotExist();
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("shows tabs when category is in whitelist", async function (assert) {
      this.siteSettings.babel_reunited_enabled_categories = "42";
      this.set("post", createPost({ topic: { category_id: 42 } }));
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs").exists();
    });

    test("shows tabs when whitelist is empty", async function (assert) {
      this.siteSettings.babel_reunited_enabled_categories = "";
      this.set("post", createPost());
      await render(
        <template><LanguageTabsConnector @post={{this.post}} /></template>
      );

      assert.dom(".ai-language-tabs").exists();
    });
  }
);
