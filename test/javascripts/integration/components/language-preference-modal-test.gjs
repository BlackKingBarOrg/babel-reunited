import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference";

module(
  "Discourse Babel Reunited | Integration | Component | language-preference-modal",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders the searchable language picker and a disable button", async function (assert) {
      this.set("closeModal", () => {});
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      assert.dom(".babel-language-picker__filter").exists();
      assert
        .dom(".babel-language-picker__item")
        .exists("full language list is offered");
      assert.dom(".disable-btn").exists();
    });

    test("hints mark pre-translate languages as instant", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";

      this.set("closeModal", () => {});
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      await fillIn(".babel-language-picker__filter", "english");
      assert.dom(".babel-language-picker__hint").hasText("Instant");

      await fillIn(".babel-language-picker__filter", "thai");
      assert
        .dom(".babel-language-picker__hint")
        .hasText("First view takes a few seconds");
    });

    test("selecting language sends POST to user-preferred-language", async function (assert) {
      let modalClosed = false;

      pretender.post("/babel-reunited/user-preferred-language", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST language=${body.get("language")}`);
        return response({ success: true });
      });

      this.set("closeModal", () => (modalClosed = true));
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      await fillIn(".babel-language-picker__filter", "english");
      await click(".babel-language-picker__item");

      assert.verifySteps(["POST language=en"]);
      assert.true(modalClosed, "closeModal was called");
    });

    test("disable translation sends POST with enabled=false", async function (assert) {
      let modalClosed = false;

      pretender.post("/babel-reunited/user-preferred-language", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST enabled=${body.get("enabled")}`);
        return response({ success: true });
      });

      this.set("closeModal", () => (modalClosed = true));
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      await click(".disable-btn");

      assert.verifySteps(["POST enabled=false"]);
      assert.true(modalClosed, "closeModal was called");
    });
  }
);
