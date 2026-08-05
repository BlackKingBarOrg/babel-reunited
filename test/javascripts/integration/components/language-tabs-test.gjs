import { getOwner } from "@ember/owner";
import { trustHTML } from "@ember/template";
import { click, fillIn, render, settled } from "@ember/test-helpers";
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

// The view trigger waits for the element to intersect the viewport and hold.
// IntersectionObserver delivers outside the runloop, so settled() alone does
// not cover it.
async function waitForViewTrigger() {
  await new Promise((resolve) => setTimeout(resolve, 120));
  await settled();
}

module(
  "Discourse Babel Reunited | Integration | Component | language-tabs",
  function (hooks) {
    setupRenderingTest(hooks);

    // Most tests here exercise the menu, switching and async behavior, which
    // is orthogonal to the pre-translate tab row. Emptying the setting keeps
    // their tab arithmetic obvious; the row has its own tests below.
    hooks.beforeEach(function () {
      this.siteSettings.babel_reunited_auto_translate_languages = "";
    });

    test("pre-translate languages keep their own fixed tabs", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      this.set("post", createPost({ babel_translations_meta: [] }));

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      // original + en + zh-cn + es + overflow menu
      assert.dom(".ai-language-tabs button").exists({ count: 5 });
      assert.dom(".ai-language-tabs button:nth-child(2)").hasText("English");
      assert
        .dom(".ai-language-tabs button:nth-child(4)")
        .includesText("Español");
    });

    test("the post's own language gets no tab of its own", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      this.set(
        "post",
        createPost({
          babel_detected_locale: "en",
          babel_translations_meta: [],
        })
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      // original (labeled English) + zh-cn + es + overflow menu: the English
      // tab is gone because the original tab is already English
      assert.dom(".ai-language-tabs button").exists({ count: 4 });
      assert
        .dom(".ai-language-tabs button:first-child")
        .includesText("English");
      assert.dom(".ai-language-tabs button:nth-child(2)").includesText("中文");
    });

    test("a preferred language outside the pre-translate layer leads", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "th");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost({ babel_translations_meta: [] }));

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      // original + th + en + zh-cn + es + overflow menu
      assert.dom(".ai-language-tabs button").exists({ count: 6 });
      assert.dom(".ai-language-tabs button:nth-child(2)").hasText("ไทย");
    });

    test("languages that already have a tab are not repeated in the menu", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      this.set(
        "post",
        createPost({
          babel_translations_meta: [
            { language: "zh-cn", status: "completed", source_language: "en" },
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

      await openLanguageMenu();
      // Filter by the exact code: "chinese" would also match zh-tw and zh-hk.
      await fillIn(".babel-language-picker__filter", "zh-cn");

      assert
        .dom(".babel-language-picker__item")
        .doesNotExist("zh-cn is a tab, so the menu does not offer it again");
    });

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
      assert
        .dom(".babel-language-picker__note")
        .exists("the on-demand caveat is stated once, not on every row");
      assert
        .dom(".babel-language-picker__hint")
        .doesNotExist("no per-row hint when nothing is instant here");
    });

    test("languages are listed by their own name and found by it", async function (assert) {
      this.set("post", createPost({ babel_translations_meta: [] }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();

      // A reader searching for their own language types it the way they write
      // it, not the way the interface locale spells it.
      await fillIn(".babel-language-picker__filter", "\u4e2d\u6587");
      assert.dom(".babel-language-picker__item").exists();
      assert
        .dom(".babel-language-picker__secondary")
        .exists("the interface-locale name stays visible");

      // The interface-locale name and the code still work.
      await fillIn(".babel-language-picker__filter", "Simplified Chinese");
      assert.dom(".babel-language-picker__item").exists({ count: 1 });

      await fillIn(".babel-language-picker__filter", "zh-cn");
      assert.dom(".babel-language-picker__item").exists({ count: 1 });
    });

    test("a language whose own name matches the interface locale shows once", async function (assert) {
      this.set("post", createPost({ babel_translations_meta: [] }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      // "english" would also match en-us, en-gb and friends; fil is unique
      // and its own name is the same as its English one.
      await fillIn(".babel-language-picker__filter", "filipino");

      assert.dom(".babel-language-picker__item").exists({ count: 1 });
      assert.dom(".babel-language-picker__name").hasText("Filipino");
      assert
        .dom(".babel-language-picker__secondary")
        .doesNotExist("no point repeating the same name twice");
    });

    test("country-level variants are not offered", async function (assert) {
      this.set("post", createPost({ babel_translations_meta: [] }));
      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "english");

      // Only "English": American/British/Australian... translate to the same
      // text at N times the price and fragment the cache.
      assert.dom(".babel-language-picker__item").exists({ count: 1 });
      assert.dom(".babel-language-picker__name").hasText("English");

      // A script difference is a real difference and stays on offer.
      await fillIn(".babel-language-picker__filter", "zh-");
      assert.dom(".babel-language-picker__item").exists({ count: 2 });
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
      assert.dom(".babel-language-picker__item").includesText("ไทย");
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

    test("picking an in-flight language fetches but never re-requests", async function (assert) {
      this.set(
        "post",
        createPost({
          babel_translations_meta: [
            { language: "vi", status: "translating", source_language: null },
          ],
        })
      );
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("POST called");
          return response({ status: "queued" });
        }
      );
      pretender.get(
        `/babel-reunited/posts/${this.post.id}/translations/vi.json`,
        () => {
          assert.step("GET body");
          return response({
            post_translation: {
              language: "vi",
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
      await fillIn(".babel-language-picker__filter", "vietnamese");
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
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("POST called");
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

    test("a late detection removes the tab offering the post's own language", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      // Rendered before detection finished, so the post's language is unknown
      // and the preferred tab is offered as it would be for any post.
      this.set(
        "post",
        createPost({
          babel_detected_locale: null,
          babel_translations_meta: [],
        })
      );

      await render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      assert.dom(".ai-language-tabs button").exists({ count: 3 });

      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        post_id: this.post.id,
        detected_locale: "zh-cn",
      });

      assert
        .dom(".ai-language-tabs button")
        .exists({ count: 2 }, "only original and the overflow menu remain");
      assert.dom(".ai-language-tabs button:first-child").includesText("中文");
    });

    test("a source_language refusal teaches the client and falls back to original", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "zh-cn");
      currentUser.set("preferred_language_enabled", true);

      this.set(
        "post",
        createPost({
          babel_detected_locale: null,
          babel_translations_meta: [],
        })
      );
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("POST");
          return response({
            status: "noop",
            reason: "source_language",
            detected_locale: "zh-cn",
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

      await click(".ai-language-tabs button:nth-child(2)");

      assert.verifySteps(["POST"]);
      assert.dom(".cooked").hasText("Original cooked content");
      assert
        .dom(".ai-language-tabs button")
        .exists({ count: 2 }, "the redundant tab is gone");
      assert
        .dom(".ai-language-tabs .spinner.small")
        .doesNotExist("no lingering spinner");
    });

    test("picking the source language shows the original, it does not translate", async function (assert) {
      this.set("post", createPost({ babel_detected_locale: "th" }));
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("POST");
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
      await fillIn(".babel-language-picker__filter", "thai");

      assert
        .dom(".babel-language-picker__hint")
        .hasText("Source language", "the entry is tagged, not hidden");

      await click(".babel-language-picker__item");

      assert.verifySteps([], "asking for the post's own language costs nothing");
      assert.dom(".cooked").hasText("Original cooked content");
      assert
        .dom(".ai-language-tabs .spinner.small")
        .doesNotExist("no translation was started");
    });

    test("a translation into the post's own language is never auto-selected", async function (assert) {
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "es");
      currentUser.set("preferred_language_enabled", true);

      // The post was rewritten in Spanish; the old es translation survives as
      // stale content that nothing will ever refresh.
      this.set(
        "post",
        createPost({
          babel_detected_locale: "es",
          babel_translations_meta: [
            { language: "es", status: "stale", source_language: "en" },
          ],
          babel_preferred_translation: {
            language: "es",
            status: "stale",
            translated_content: "<p>Contenido anterior a la edicion</p>",
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

      assert
        .dom(".cooked")
        .hasText("Original cooked content", "the original is the Spanish text");
      assert
        .dom(".babel-reunited-stale-notice")
        .doesNotExist("no stale body is on screen");
    });

    test("a late fetch does not override a newer language choice", async function (assert) {
      let resolveFetch;
      this.set("post", createPost());
      pretender.get(
        `/babel-reunited/posts/${this.post.id}/translations/zh-cn.json`,
        () => new Promise((resolve) => (resolveFetch = resolve))
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

      // Deliberately not awaited: the test helpers settle on pending AJAX,
      // which is exactly what this test keeps in flight. The switch below
      // uses a raw DOM click for the same reason.
      const pendingClick = click(".babel-language-picker__item.--translated");
      await new Promise((resolve) => setTimeout(resolve, 10));

      // The reader gives up waiting and goes back to the original.
      document.querySelector(".ai-language-tabs button:first-child").click();
      await new Promise((resolve) => setTimeout(resolve, 10));

      resolveFetch(
        response({
          post_translation: {
            language: "zh-cn",
            status: "completed",
            translated_content: "<p>中文翻译</p>",
          },
        })
      );
      await pendingClick;
      await settled();

      assert
        .dom(".cooked")
        .hasText("Original cooked content", "newer choice wins");
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
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("refresh requested");
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

      assert.dom(".cooked").hasText("Alte Übersetzung", "stale body displays");
      assert
        .dom(".babel-reunited-stale-notice")
        .exists("stale content is labeled");

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
      await waitForViewTrigger();

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
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          assert.step("POST called");
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
      await waitForViewTrigger();

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
      await waitForViewTrigger();
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
      await waitForViewTrigger();

      assert.verifySteps([], "no second request for the same pair");
    });

    test("a late view-trigger response does not steal the reader's own choice", async function (assert) {
      this.siteSettings.babel_reunited_view_triggered_translation = true;
      this.siteSettings.babel_reunited_auto_translate_languages = "ja";
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "th");
      currentUser.set("preferred_language_enabled", true);

      let resolveViewTrigger;
      this.set("post", createPost({ babel_translations_meta: [] }));
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        (request) => {
          const body = new URLSearchParams(request.requestBody);
          if (body.get("trigger") === "view") {
            return new Promise((resolve) => (resolveViewTrigger = resolve));
          }
          return response({ status: "queued" });
        }
      );

      // Deliberately not awaited: the view trigger fires during render's
      // settling and its POST is the request this test holds in flight, so
      // awaiting render (or any settling helper) would deadlock. Raw timers
      // and DOM clicks below for the same reason.
      const rendered = render(
        <template>
          <LanguageTabsConnector @post={{this.post}}>
            <div class="cooked">{{trustHTML this.post.cooked}}</div>
          </LanguageTabsConnector>
        </template>
      );

      // Wait until the automatic view trigger has fired.
      for (let i = 0; i < 100 && !resolveViewTrigger; i++) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }

      // The reader picks Japanese through its fixed tab (original, th, ja).
      document.querySelector(".ai-language-tabs button:nth-child(3)").click();
      await new Promise((resolve) => setTimeout(resolve, 50));

      // The abandoned view-trigger response lands late.
      resolveViewTrigger(response({ status: "queued" }));
      await rendered;
      await settled();

      // The preferred language finishing first must not hijack the view...
      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        status: "completed",
        language: "th",
        translation: {
          language: "th",
          status: "completed",
          translated_content: "<p>คำแปลภาษาไทย</p>",
        },
      });
      assert
        .dom(".cooked")
        .hasText("Original cooked content", "th completion does not switch");

      // ...while the language the reader actually asked for still does.
      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        status: "completed",
        language: "ja",
        translation: {
          language: "ja",
          status: "completed",
          translated_content: "<p>日本語訳</p>",
        },
      });
      assert.dom(".cooked").hasText("日本語訳", "the reader's choice wins");
    });

    test("on-demand translation auto-switches on MessageBus completion", async function (assert) {
      this.set("post", createPost());
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
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

    test("a failing request does not cancel a newer pending one", async function (assert) {
      let failJa;
      const currentUser = getOwner(this).lookup("service:current-user");
      currentUser.set("preferred_language", "ko");
      currentUser.set("preferred_language_enabled", true);

      this.set("post", createPost());
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        (request) => {
          const body = new URLSearchParams(request.requestBody);
          if (body.get("target_language") === "ja") {
            return new Promise((resolve) => (failJa = resolve));
          }
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

      // Ask for Japanese; the request stays in flight.
      await openLanguageMenu();
      await fillIn(".babel-language-picker__filter", "japanese");
      const pendingJa = click(".babel-language-picker__item");
      await new Promise((resolve) => setTimeout(resolve, 10));

      // Change your mind and ask for Korean through the fixed preferred tab.
      // Raw DOM click: the test helpers settle on the in-flight request.
      document.querySelector(".ai-language-tabs button:nth-child(2)").click();
      await new Promise((resolve) => setTimeout(resolve, 50));

      // The abandoned Japanese request now fails.
      failJa(response(429, { errors: ["rate limited"] }));
      await pendingJa;
      await settled();

      // Korean is still what the reader is waiting for, so its completion
      // must still switch the view.
      await publishToMessageBus(`/post-translations/${this.post.id}`, {
        status: "completed",
        language: "ko",
        translation: {
          language: "ko",
          status: "completed",
          translated_content: "<p>한국어 번역</p>",
        },
      });

      assert.dom(".cooked").hasText("한국어 번역");
    });

    test("manual request reverts optimistic state on error", async function (assert) {
      this.set("post", createPost());
      pretender.post(
        `/babel-reunited/posts/${this.post.id}/translations`,
        () => {
          return response(429, { errors: ["rate limited"] });
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
