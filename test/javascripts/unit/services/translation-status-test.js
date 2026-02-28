import { getOwner } from "@ember/owner";
import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import sinon from "sinon";

module(
  "Discourse Babel Reunited | Unit | Service | translation-status",
  function (hooks) {
    setupTest(hooks);

    hooks.beforeEach(function () {
      this.subject = getOwner(this).lookup("service:translation-status");
    });

    test("getTranslationStatus returns idle when no state exists", function (assert) {
      const result = this.subject.getTranslationStatus(1, "en");
      assert.deepEqual(result, { status: "idle" });
    });

    test("handleTranslationUpdate creates new post state and stores it", function (assert) {
      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "completed",
        error: null,
        translation_id: 42,
        translated_content: "<p>Hello</p>",
        timestamp: "2026-01-01T00:00:00Z",
      });

      const result = this.subject.getTranslationStatus(1, "en");
      assert.strictEqual(result.status, "completed");
      assert.strictEqual(result.translation_id, 42);
      assert.strictEqual(result.translated_content, "<p>Hello</p>");
    });

    test("handleTranslationUpdate updates existing language state", function (assert) {
      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "started",
        error: null,
        translation_id: 42,
        translated_content: null,
        timestamp: "2026-01-01T00:00:00Z",
      });

      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "completed",
        error: null,
        translation_id: 42,
        translated_content: "<p>Updated</p>",
        timestamp: "2026-01-01T00:01:00Z",
      });

      const result = this.subject.getTranslationStatus(1, "en");
      assert.strictEqual(result.status, "completed");
      assert.strictEqual(result.translated_content, "<p>Updated</p>");
    });

    test("handleTranslationUpdate triggers translation:status-changed appEvent", function (assert) {
      const appEvents = getOwner(this).lookup("service:app-events");
      const spy = sinon.spy(appEvents, "trigger");

      this.subject.handleTranslationUpdate(1, {
        target_language: "zh",
        status: "completed",
        error: null,
        translation_id: 10,
        translated_content: "<p>你好</p>",
        timestamp: "2026-01-01T00:00:00Z",
      });

      assert.true(
        spy.calledWith("translation:status-changed", {
          postId: 1,
          targetLanguage: "zh",
          status: "completed",
          error: null,
          translationId: 10,
          translatedContent: "<p>你好</p>",
        })
      );
    });

    test("handleTranslationUpdate triggers modal:alert for started, completed, and failed", function (assert) {
      const appEvents = getOwner(this).lookup("service:app-events");
      const spy = sinon.spy(appEvents, "trigger");

      // started
      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "started",
        error: null,
        translation_id: 1,
        translated_content: null,
        timestamp: "2026-01-01T00:00:00Z",
      });

      assert.true(
        spy.calledWith("modal:alert", {
          message: "Translation started for English...",
          type: "info",
        }),
        "triggers info alert for started"
      );

      spy.resetHistory();

      // completed
      this.subject.handleTranslationUpdate(1, {
        target_language: "es",
        status: "completed",
        error: null,
        translation_id: 2,
        translated_content: "<p>Hola</p>",
        timestamp: "2026-01-01T00:01:00Z",
      });

      assert.true(
        spy.calledWith("modal:alert", {
          message: "Translation completed for Español!",
          type: "success",
        }),
        "triggers success alert for completed"
      );

      spy.resetHistory();

      // failed
      this.subject.handleTranslationUpdate(1, {
        target_language: "zh",
        status: "failed",
        error: "Provider error",
        translation_id: 3,
        translated_content: null,
        timestamp: "2026-01-01T00:02:00Z",
      });

      assert.true(
        spy.calledWith("modal:alert", {
          message: "Translation failed for 中文: Provider error",
          type: "error",
        }),
        "triggers error alert for failed"
      );
    });

    test("hasPendingTranslation returns true when status is started", function (assert) {
      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "started",
        error: null,
        translation_id: 1,
        translated_content: null,
        timestamp: "2026-01-01T00:00:00Z",
      });

      assert.true(this.subject.hasPendingTranslation(1, "en"));
    });

    test("hasPendingTranslation returns false when status is completed", function (assert) {
      this.subject.handleTranslationUpdate(1, {
        target_language: "en",
        status: "completed",
        error: null,
        translation_id: 1,
        translated_content: "<p>Hello</p>",
        timestamp: "2026-01-01T00:00:00Z",
      });

      assert.false(this.subject.hasPendingTranslation(1, "en"));
    });

    test("subscribeToTopic calls messageBus.subscribe with correct channel", function (assert) {
      const messageBus = getOwner(this).lookup("service:message-bus");
      const spy = sinon.spy(messageBus, "subscribe");

      this.subject.subscribeToTopic(42);

      assert.true(spy.calledOnce, "subscribe called once");
      assert.strictEqual(
        spy.firstCall.args[0],
        "/post-translations/42",
        "subscribes to correct channel"
      );
      assert.strictEqual(
        typeof spy.firstCall.args[1],
        "function",
        "passes callback function"
      );
    });
  }
);
