import { getOwner } from "@ember/owner";
import { click, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
import sinon from "sinon";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference";

module(
  "Discourse Babel Reunited | Integration | Component | language-preference-modal",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders 3 language buttons and a disable button", async function (assert) {
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
      assert.dom(".language-btn-en").exists();
      assert.dom(".language-btn-zh-cn").exists();
      assert.dom(".language-btn-es").exists();
      assert.dom(".disable-btn").exists();
    });

    test("selecting language sends POST to user-preferred-language", async function (assert) {
      const modalService = getOwner(this).lookup("service:modal");
      sinon.spy(modalService, "close");

      pretender.post("/babel-reunited/user-preferred-language", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST language=${body.get("language")}`);
        return response({ success: true });
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

      await click(".language-btn-en");

      assert.verifySteps(["POST language=en"]);
      assert.true(modalService.close.calledOnce, "modal service close called");
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

      // Start the request without awaiting
      click(".language-btn-en");

      // Wait for the saving state to take effect
      await new Promise((resolve) => setTimeout(resolve, 10));

      assert.dom(".language-btn-zh-cn").isDisabled();
      assert.dom(".language-btn-es").isDisabled();
      assert.dom(".disable-btn").isDisabled();

      // Resolve the request to clean up
      resolveRequest(response({ success: true }));
      await settled();
    });

    test("disable translation sends POST with enabled=false", async function (assert) {
      const modalService = getOwner(this).lookup("service:modal");
      sinon.spy(modalService, "close");

      pretender.post("/babel-reunited/user-preferred-language", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST enabled=${body.get("enabled")}`);
        return response({ success: true });
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

      await click(".disable-btn");

      assert.verifySteps(["POST enabled=false"]);
      assert.true(modalService.close.calledOnce, "modal service close called");
    });
  }
);
