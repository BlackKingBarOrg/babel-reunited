import { getOwner } from "@ember/owner";
import { trustHTML } from "@ember/template";
import { click, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line simple-import-sort/imports, discourse/ui-kit-imports
import { resetHtmlDecorators } from "discourse/components/decorated-html";
import { withPluginApi } from "discourse/lib/plugin-api";
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs button").exists({ count: 4 });
    });

    test("default selection is original, displaying post.cooked", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("clicking completed language shows translated content", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      // Button order follows site setting default: en(2), zh-cn(3), es(4)
      await click(".ai-language-tabs button:nth-child(2)");

      assert.dom(".cooked").hasText("English translation");
    });

    test("clicking Original restores post.cooked content", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await click(".ai-language-tabs button:nth-child(4)");

      assert
        .dom(".ai-language-tabs button:nth-child(4) .spinner.small")
        .doesNotExist("spinner removed after error");
    });

    test("Tripwire: currentContent in original mode returns post.cooked not post.raw", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".cooked").hasText("中文翻译");
    });

    test("shows disabled text when preferred_language_enabled is false", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language_enabled", false);

      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs").doesNotExist();
    });

    test("shows spinner icon for translating status", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs .spinner.small").exists();
    });

    test("MessageBus update refreshes translation data and UI", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
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
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs").doesNotExist();
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("shows tabs when category is in whitelist", async function (assert) {
      this.siteSettings.babel_reunited_enabled_categories = "42";
      this.set("post", createPost({ topic: { category_id: 42 } }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs").exists();
    });

    test("shows tabs when whitelist is empty", async function (assert) {
      this.siteSettings.babel_reunited_enabled_categories = "";
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs").exists();
    });

    test("original mode renders the yielded block, not PostCookedHtml", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked" data-yielded-block>
              {{trustHTML this.post.cooked}}
            </div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom("[data-yielded-block]").exists("block content is rendered");
      assert.dom(".cooked").exists({ count: 1 });
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("translated mode replaces the block with PostCookedHtml output", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked" data-yielded-block>
              {{trustHTML this.post.cooked}}
            </div>
          </LanguageTabsConnector>
        </template>
      );

      await click(".ai-language-tabs button:nth-child(2)");

      assert
        .dom("[data-yielded-block]")
        .doesNotExist("block is not rendered in translated mode");
      assert.dom(".cooked").exists({ count: 1 });
      assert.dom(".cooked").hasText("English translation");
    });

    test("switching languages never duplicates the post body", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      const sequence = [2, 1, 3, 1, 2];
      for (const position of sequence) {
        await click(`.ai-language-tabs button:nth-child(${position})`);
        assert.dom(".cooked").exists({ count: 1 }, `single body after switching to button ${position}`);
      }
    });

    test("cooked decorators run on translated content and clean up on switch", async function (assert) {
      let applied = 0;
      let cleaned = 0;
      withPluginApi((api) => {
        api.decorateCookedElement(() => {
          applied += 1;
          return () => (cleaned += 1);
        });
      });

      try {
        this.set("post", createPost());
        await render(
          <template>
            <LanguageTabsConnector @post={{this.post}}>
              <div class="cooked">{{trustHTML this.post.cooked}}</div>
            </LanguageTabsConnector>
          </template>
        );

        assert.strictEqual(applied, 0, "no decoration in original mode (yield)");

        await click(".ai-language-tabs button:nth-child(2)");
        assert.true(applied >= 1, "decorator ran for translated content");

        const appliedBeforeSwitch = applied;
        await click(".ai-language-tabs button:first-child");
        assert.strictEqual(
          cleaned,
          appliedBeforeSwitch,
          "every decoration was cleaned up when leaving the translated view"
        );
      } finally {
        resetHtmlDecorators();
      }
    });
  }
);
