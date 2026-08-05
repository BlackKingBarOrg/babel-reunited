import { click, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import BabelLanguagePicker from "discourse/plugins/babel-reunited/discourse/components/babel-language-picker";

module(
  "Discourse Babel Reunited | Integration | Component | babel-language-picker",
  function (hooks) {
    setupRenderingTest(hooks);

    // The plugin stylesheet is not loaded here, so the list would be neither
    // scrollable nor laid out in rows and these assertions would measure
    // nothing. This mirrors the parts of language-tabs.scss the scrolling
    // depends on, at a height small enough to force a scroll.
    hooks.beforeEach(function () {
      this.layout = document.createElement("style");
      this.layout.textContent = `
        .babel-language-picker__list {
          display: flex;
          flex-direction: column;
          max-height: 100px;
          overflow-y: auto;
          position: relative;
        }
        .babel-language-picker__item {
          display: block;
          width: 100%;
          padding: 6px;
          border: none;
        }
      `;
      document.head.appendChild(this.layout);
    });

    hooks.afterEach(function () {
      this.layout.remove();
    });

    function listEl() {
      return document.querySelector(".babel-language-picker__list");
    }

    // The modifier keeps re-aligning while webfonts change the height of the
    // rows above the selection, so wait for the position to hold still rather
    // than for a fixed number of frames.
    async function settleLayout() {
      await document.fonts.ready;

      const list = listEl();
      let previous = -1;
      let stable = 0;
      for (let frame = 0; frame < 120 && stable < 5; frame++) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        stable = list.scrollTop === previous ? stable + 1 : 0;
        previous = list.scrollTop;
      }
    }

    test("opens on the current selection when it sits far down the list", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      this.set("instantCodes", ["en", "zh-cn", "es"]);

      await render(
        <template>
          <BabelLanguagePicker
            @selectedCode="zh-tw"
            @instantCodes={{this.instantCodes}}
            @groupInstant={{true}}
            @showHints={{true}}

          />
        </template>
      );

      await settleLayout();

      const list = listEl();
      const selected = list.querySelector(".--selected");

      assert.true(list.scrollTop > 0, "the list did not open at the top");

      // Content coordinates, not viewport ones: the Ember test container is
      // scaled, so rects and scrollTop are not in the same units.
      const top = selected.offsetTop - list.scrollTop;
      assert.true(top >= 0, "the selected language is not above the visible box");
      assert.true(
        top + selected.offsetHeight <= list.clientHeight,
        "the selected language is not below the visible box"
      );
    });

    test("leaves the list at the top when the selection is already visible", async function (assert) {
      this.siteSettings.babel_reunited_auto_translate_languages = "en,zh-cn,es";
      this.set("instantCodes", ["en", "zh-cn", "es"]);

      await render(
        <template>
          <BabelLanguagePicker
            @selectedCode="en"
            @instantCodes={{this.instantCodes}}
            @groupInstant={{true}}
            @showHints={{true}}

          />
        </template>
      );

      assert.strictEqual(listEl().scrollTop, 0);
    });

    test("leaves the list at the top when nothing is selected", async function (assert) {
      await render(
        <template>
          <BabelLanguagePicker @showHints={{true}} />
        </template>
      );

      assert.strictEqual(listEl().scrollTop, 0);
    });

    test("selects a language when enabled", async function (assert) {
      const picked = [];
      this.set("onSelect", (code) => picked.push(code));

      await render(
        <template>
          <BabelLanguagePicker @onSelect={{this.onSelect}} />
        </template>
      );

      await click(".babel-language-picker__item");
      assert.strictEqual(picked.length, 1);
    });

    // While a save is in flight the picker is handed @disabled; a click then
    // must neither look clickable nor reach onSelect (a second selection
    // racing the first save is how a preference gets silently overwritten).
    test("ignores selection while disabled", async function (assert) {
      const picked = [];
      this.set("onSelect", (code) => picked.push(code));

      await render(
        <template>
          <BabelLanguagePicker @disabled={{true}} @onSelect={{this.onSelect}} />
        </template>
      );

      const item = document.querySelector(".babel-language-picker__item");
      assert.true(item.disabled, "items render as disabled buttons");

      // A programmatic dispatch bypasses the browser's disabled handling, so
      // this exercises the action-level guard as well.
      item.dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true })
      );
      await settled();

      assert.strictEqual(picked.length, 0);
    });
  }
);
