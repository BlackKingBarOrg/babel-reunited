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

    test("groups the pre-translate layer above everything else", async function (assert) {
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

      const labels = [
        ...document.querySelectorAll(".babel-language-picker__group-label"),
      ].map((el) => el.textContent.trim());
      assert.deepEqual(
        labels,
        [
          "Pre-translated by this site",
          "Other languages · translated on first view",
        ],
        "instant and on-demand languages are separated"
      );

      // Everything between the two headings is the configured layer.
      const nodes = [
        ...document.querySelectorAll(
          ".babel-language-picker__group-label, .babel-language-picker__item"
        ),
      ];
      const secondHeading = nodes.findIndex(
        (node, index) =>
          index > 0 &&
          node.classList.contains("babel-language-picker__group-label")
      );
      assert.strictEqual(
        secondHeading - 1,
        3,
        "the three configured languages lead the list"
      );

      // The warning now sits on the group it describes, instead of above a
      // list where it is false for the pre-translated three.
      assert.dom(".babel-language-picker__note").doesNotExist();
      assert
        .dom(".babel-language-picker__hint")
        .doesNotExist("the group heading replaces the per-row badge");
    });

    test("drops a group heading when the filter empties that group", async function (assert) {
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

      await fillIn(".babel-language-picker__filter", "thai");
      assert
        .dom(".babel-language-picker__group-label")
        .doesNotExist("a lone list needs no heading");
      assert.dom(".babel-language-picker__item").exists();

      await fillIn(".babel-language-picker__filter", "espa");
      assert
        .dom(".babel-language-picker__group-label")
        .hasText("Pre-translated by this site");
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

      await fillIn(".babel-language-picker__filter", "zh-cn");
      await click(".babel-language-picker__item");

      assert.verifySteps(["POST language=zh-cn"]);
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
