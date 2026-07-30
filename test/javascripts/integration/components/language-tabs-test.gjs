import { getOwner } from "@ember/owner";
import { trustHTML } from "@ember/template";
import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line discourse/ui-kit-imports
import { resetHtmlDecorators } from "discourse/components/decorated-html";
import { withPluginApi } from "discourse/lib/plugin-api";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import { publishToMessageBus } from "discourse/tests/helpers/qunit-helpers";
import LanguageTabsConnector from "discourse/plugins/babel-reunited/discourse/connectors/before-post-article/language-tabs";

let postCounter = 0;

// Each test uses a unique post id: the connector deduplicates automatic
// view-trigger requests per (post, language) in module state that survives
// across tests.
function createPost(overrides = {}) {
  postCounter += 1;
  return Object.assign(
    {
      id: postCounter,
      cooked: "<p>Original cooked content</p>",
      raw: "Original raw content",
      babel_detected_locale: null,
      babel_translations_meta: [
        { language: "en", status: "completed", source_language: "en" },
        { language: "zh-cn", status: "completed", source_language: "en" },
        { language: "es", status: "translating", source_language: null },
      ],
      babel_preferred_translation: null,
    },
    overrides
  );
}

async function openLanguageMenu() {
  await click(".babel-reunited-language-tab.--menu");
}

module(
  "Discourse Babel Reunited | Integration | Component | language-tabs",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders the original tab and the overflow menu trigger", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs button").exists({ count: 2 });
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("labels the original tab with the detected language", async function (assert) {
      this.set("post", createPost({ babel_detected_locale: "en" }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert
        .dom(".ai-language-tabs button:first-child")
        .includesText("English");
    });

    test("overflow menu groups translated languages first with hints on the rest", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();

      assert
        .dom(".babel-language-picker__item.--translated")
        .exists({ count: 2 }, "en and zh-cn are grouped as translated");
      assert.dom(".babel-language-picker__hint").exists("hints on the rest");
    });

    test("menu search filters the language list", async function (assert) {
      this.set("post", createPost());
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "thai");

      assert.dom(".babel-language-picker__item").exists({ count: 1 });
      assert.dom(".babel-language-picker__item").includesText("Thai");
    });

    test("picking a translated language fetches its body on demand", async function (assert) {
      this.set("post", createPost());
      pretender.get(
        `/babel-reunited/posts/${this.post.id}/translations/zh-cn.json`,
        () => {
          assert.step("GET body");
          return response({
            post_translation: {
              language: "zh-cn",
              status: "completed",
              translated_content: "<p>中文翻译</p>",
            },
          });
        }
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "chinese");
      await click(".babel-language-picker__item.--translated");

      assert.verifySteps(["GET body"]);
      assert.dom(".cooked").hasText("中文翻译");
    });

    test("picking an untranslated language requests a translation", async function (assert) {
      this.set("post", createPost());
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        (request) => {
          const body = new URLSearchParams(request.requestBody);
          assert.step(`POST target_language=${body.get("target_language")}`);
          return response({ status: "queued" });
        }
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "japanese");
      await click(".babel-language-picker__item");

      assert.verifySteps(["POST target_language=ja"]);
      assert
        .dom(".ai-language-tabs .spinner.small")
        .exists("shows spinner on the transient tab");
    });

    test("the detected language is excluded from the picker", async function (assert) {
      this.set("post", createPost({ babel_detected_locale: "th" }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "thai");

      assert
        .dom(".babel-language-picker__item")
        .doesNotExist("the original tab already covers the post's language");
    });

    test("picking an in-flight language fetches but never re-requests", async function (assert) {
      this.set("post", createPost());
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        assert.step("POST called");
        return response({ status: "queued" });
      });
      pretender.get(
        `/babel-reunited/posts/${this.post.id}/translations/es.json`,
        () => {
          assert.step("GET body");
          return response({
            post_translation: {
              language: "es",
              status: "translating",
              translated_content: "",
            },
          });
        }
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "spanish");
      await click(".babel-language-picker__item");

      // A fresh in-flight record has no body yet: one read, no new job.
      assert.verifySteps(["GET body"]);
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("a re-translating record with an old body stays readable", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_translations_meta: [
            { language: "zh-cn", status: "translating", source_language: "en" },
          ],
          babel_preferred_translation: {
            language: "zh-cn",
            status: "translating",
            translated_content: "<p>旧的中文翻译</p>",
          },
        })
      );
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        assert.step("POST called");
        return response({ status: "queued" });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".cooked").hasText("旧的中文翻译", "old body auto-selected");
      assert.verifySteps([], "no request while the run is in flight");

      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        status: "completed",
        language: "zh-cn",
        translation: {
          language: "zh-cn",
          status: "completed",
          translated_content: "<p>新的中文翻译</p>",
        },
      });

      assert.dom(".cooked").hasText("新的中文翻译", "fresh body swaps in");
    });

    test("preferred language with preloaded body auto-selects and shows its own tab", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_preferred_translation: {
            language: "zh-cn",
            status: "completed",
            translated_content: "<p>中文翻译</p>",
          },
        })
      );
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".cooked").hasText("中文翻译");
      assert.dom(".ai-language-tabs button").exists({ count: 3 });
    });

    test("preferred tab is hidden when the post is already in that language", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "en");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost({ babel_detected_locale: "en" }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs button").exists({ count: 2 });
      assert.dom(".cooked").hasText("Original cooked content");
    });

    test("stale preferred content is shown and silently refreshed on click", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "de");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_translations_meta: [
            { language: "de", status: "stale", source_language: "en" },
          ],
          babel_preferred_translation: {
            language: "de",
            status: "stale",
            translated_content: "<p>Alte Übersetzung</p>",
          },
        })
      );
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        assert.step("refresh requested");
        return response({ status: "queued" });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".cooked").hasText("Alte Übersetzung", "stale body displays");

      await click(".ai-language-tabs button:nth-child(2)");
      assert.verifySteps(["refresh requested"]);
      assert.dom(".cooked").hasText("Alte Übersetzung", "still readable");
    });

    test("view trigger fires for a missing preferred translation when enabled", async function (assert) {
      this.siteSettings.babel_reunited_view_triggered_translation = true;
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "th");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost());
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        (request) => {
          const body = new URLSearchParams(request.requestBody);
          assert.step(
            `POST ${body.get("target_language")} trigger=${body.get("trigger")}`
          );
          return response({ status: "queued" });
        }
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.verifySteps(["POST th trigger=view"]);
      assert
        .dom(".ai-language-tabs .spinner.small")
        .exists("preferred tab shows translating");
    });

    test("view trigger stays quiet when the setting is disabled", async function (assert) {
      this.siteSettings.babel_reunited_view_triggered_translation = false;
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "th");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost());
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        assert.step("POST called");
        return response({ status: "queued" });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.verifySteps([]);
    });

    test("view trigger only fires once per post and language", async function (assert) {
      this.siteSettings.babel_reunited_view_triggered_translation = true;
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "th");
      currentUser.set("preferred_language_enabled", true);

      const post = createPost();
      this.set("post", post);
      pretender.post(`/babel-reunited/posts/${post.id}/translations`, () => {
        assert.step("POST called");
        return response({ status: "noop", reason: "disabled" });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );
      assert.verifySteps(["POST called"]);

      // Re-render the same post (cloak/uncloak cycle)
      this.set("post", { ...post });
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.verifySteps([], "no second request for the same pair");
    });

    test("on-demand translation auto-switches on MessageBus completion", async function (assert) {
      this.set("post", createPost());
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        return response({ status: "queued" });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "japanese");
      await click(".babel-language-picker__item");

      assert.dom(".cooked").hasText("Original cooked content");

      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        status: "completed",
        language: "ja",
        translation: {
          language: "ja",
          status: "completed",
          translated_content: "<p>日本語訳</p>",
        },
      });

      assert.dom(".cooked").hasText("日本語訳");
    });

    test("manual request reverts optimistic state on error", async function (assert) {
      this.set("post", createPost());
      pretender.post(`/babel-reunited/posts/${this.post.id}/translations`, () => {
        return response(429, { errors: ["rate limited"] });
      });

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "japanese");
      await click(".babel-language-picker__item");

      assert
        .dom(".ai-language-tabs .spinner.small")
        .doesNotExist("spinner removed after error");
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
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_preferred_translation: {
            language: "zh-cn",
            status: "completed",
            translated_content: "<p>中文翻译</p>",
          },
        })
      );
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked" data-yielded-block>
              {{trustHTML this.post.cooked}}
            </div>
          </LanguageTabsConnector>
        </template>
      );

      assert
        .dom("[data-yielded-block]")
        .doesNotExist("block is not rendered in translated mode");
      assert.dom(".cooked").exists({ count: 1 });
      assert.dom(".cooked").hasText("中文翻译");
    });

    test("switching languages never duplicates the post body", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_preferred_translation: {
            language: "zh-cn",
            status: "completed",
            translated_content: "<p>中文翻译</p>",
          },
        })
      );
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      const sequence = [1, 2, 1, 2];
      for (const position of sequence) {
        await click(`.ai-language-tabs button:nth-child(${position})`);
        assert
          .dom(".cooked")
          .exists({ count: 1 }, `single body after button ${position}`);
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

      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      try {
        this.set(
          "post",
          createPost({
            babel_preferred_translation: {
              language: "zh-cn",
              status: "completed",
              translated_content: "<p>中文翻译</p>",
            },
          })
        );
        await render(
          <template>
            <LanguageTabsConnector @post={{this.post}}>
              <div class="cooked">{{trustHTML this.post.cooked}}</div>
            </LanguageTabsConnector>
          </template>
        );

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
