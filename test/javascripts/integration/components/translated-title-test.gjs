import { render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import TranslatedTitle from "discourse/plugins/babel-reunited/discourse/connectors/topic-list-after-title/translated-title";

module(
  "Discourse Babel Reunited | Integration | Component | translated-title",
  function (hooks) {
    setupRenderingTest(hooks);

    test("renders translated title when different from original", async function (assert) {
      this.set("topic", {
        id: 1,
        title: "Original Title",
        translated_title: "翻译标题",
        url: "/t/original-title/1",
      });

      await render(
        <template><TranslatedTitle @topic={{this.topic}} /></template>
      );

      assert.dom(".ai-translated-title-after").exists();
      assert.dom(".translated-title-link").hasText("翻译标题");
    });

    test("does not render when translated_title is empty", async function (assert) {
      this.set("topic", {
        id: 1,
        title: "Original Title",
        translated_title: "",
        url: "/t/original-title/1",
      });

      await render(
        <template><TranslatedTitle @topic={{this.topic}} /></template>
      );

      assert.dom(".ai-translated-title-after").doesNotExist();
    });

    test("does not render when translated_title equals original title", async function (assert) {
      this.set("topic", {
        id: 1,
        title: "Same Title",
        translated_title: "Same Title",
        url: "/t/same-title/1",
      });

      await render(
        <template><TranslatedTitle @topic={{this.topic}} /></template>
      );

      assert.dom(".ai-translated-title-after").doesNotExist();
    });

    test("does not render when topic is null", async function (assert) {
      this.set("topic", null);

      await render(
        <template><TranslatedTitle @topic={{this.topic}} /></template>
      );

      assert.dom(".ai-translated-title-after").doesNotExist();
    });

    test("rendered link href points to topic.url", async function (assert) {
      this.set("topic", {
        id: 1,
        title: "Original Title",
        translated_title: "Título traducido",
        url: "/t/original-title/1",
      });

      await render(
        <template><TranslatedTitle @topic={{this.topic}} /></template>
      );

      assert
        .dom(".translated-title-link")
        .hasAttribute("href", "/t/original-title/1");
    });
  }
);
