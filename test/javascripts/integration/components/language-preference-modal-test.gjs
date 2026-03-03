import { click, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference";

module(
  "Discourse Babel Reunited | Integration | Component | language-preference-modal",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders language buttons and a disable button", async function (assert) {
      this.set("closeModal", () => {});
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      assert.dom(".language-btn").exists({ count: 3 });
      assert.dom(".disable-btn").exists();
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

      await click(".language-btn");

      assert.verifySteps(["POST language=zh-cn"]);
      assert.true(modalClosed, "closeModal was called");
    });

    test("buttons are disabled while saving", async function (assert) {
      let resolveRequest;
      pretender.post("/babel-reunited/user-preferred-language", () => {
        return new Promise((resolve) => {
          resolveRequest = resolve;
        });
      });

      this.set("closeModal", () => {});
      await render(
        <template>
          <LanguagePreferenceModal
            @closeModal={{this.closeModal}}
            @inline={{true}}
          />
        </template>
      );

      click(".language-btn");

      await new Promise((resolve) => setTimeout(resolve, 10));

      assert.dom(".language-btn:nth-child(2)").isDisabled();
      assert.dom(".language-btn:nth-child(3)").isDisabled();
      assert.dom(".disable-btn").isDisabled();

      resolveRequest(response({ success: true }));
      await settled();
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
