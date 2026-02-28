import { getOwner } from "@ember/owner";
import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import pretender, { response } from "discourse/tests/helpers/create-pretender";

module(
  "Discourse Babel Reunited | Unit | Service | translation-api",
  function (hooks) {
    setupTest(hooks);

    hooks.beforeEach(function () {
      this.subject = getOwner(this).lookup("service:translation-api");
    });

    test("getTranslations requests correct URL", async function (assert) {
      pretender.get("/babel-reunited/posts/123/translations", (request) => {
        assert.step(`GET ${request.url}`);
        return response({
          translations: [
            { language: "en", status: "completed", translated_content: "Hi" },
          ],
        });
      });

      const result = await this.subject.getTranslations(123);

      assert.verifySteps(["GET /babel-reunited/posts/123/translations"]);
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].language, "en");
    });

    test("createTranslation sends POST with target_language and force_update", async function (assert) {
      pretender.post("/babel-reunited/posts/456/translations", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.step(`POST ${request.url}`);
        assert.strictEqual(body.get("target_language"), "zh-cn");
        assert.strictEqual(body.get("force_update"), "true");
        return response({ status: "started", translation_id: 99 });
      });

      await this.subject.createTranslation(456, "zh-cn", true);

      assert.verifySteps(["POST /babel-reunited/posts/456/translations"]);
    });

    test("createTranslation forceUpdate defaults to false", async function (assert) {
      pretender.post("/babel-reunited/posts/789/translations", (request) => {
        const body = new URLSearchParams(request.requestBody);
        assert.strictEqual(body.get("force_update"), "false");
        return response({ status: "started", translation_id: 100 });
      });

      await this.subject.createTranslation(789, "es");
    });

    test("deleteTranslation sends DELETE to correct URL", async function (assert) {
      pretender.delete(
        "/babel-reunited/posts/123/translations/en",
        (request) => {
          assert.step(`DELETE ${request.url}`);
          return response({ success: true });
        }
      );

      await this.subject.deleteTranslation(123, "en");

      assert.verifySteps(["DELETE /babel-reunited/posts/123/translations/en"]);
    });

    test("getTranslationStatus requests correct URL", async function (assert) {
      pretender.get(
        "/babel-reunited/posts/123/translations/translation_status",
        (request) => {
          assert.step(`GET ${request.url}`);
          return response({ pending: [], available: ["en", "es"] });
        }
      );

      const result = await this.subject.getTranslationStatus(123);

      assert.verifySteps([
        "GET /babel-reunited/posts/123/translations/translation_status",
      ]);
      assert.deepEqual(result.available, ["en", "es"]);
    });

    test("getTranslations throws on API error", async function (assert) {
      pretender.get("/babel-reunited/posts/999/translations", () => {
        return response(500, { errors: ["Internal Server Error"] });
      });

      try {
        await this.subject.getTranslations(999);
        assert.true(false, "should have thrown");
      } catch (error) {
        assert.notStrictEqual(error, undefined, "error is propagated");
      }
    });
  }
);
