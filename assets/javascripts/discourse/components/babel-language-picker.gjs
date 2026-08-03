import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
// The ui-kit module paths suggested by the lint rule are not resolvable in
// the plugin runtime yet; the legacy paths work through core's compatibility
// shim.
// eslint-disable-next-line discourse/ui-kit-imports
import concatClass from "discourse/helpers/concat-class";
// eslint-disable-next-line discourse/ui-kit-imports
import icon from "discourse/helpers/d-icon";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { SUPPORTED_LOCALES } from "../lib/babel-locales";
import {
  languageDisplayName,
  languageEndonym,
} from "../lib/language-display-name";

// Searchable language list shared by the post-level overflow menu and the
// preference surfaces (modal + account page).
//
// @onSelect        (code) => void
// @translatedCodes codes with an existing displayable translation (grouped
//                  first, instant to open)
// @excludeCodes    codes handled elsewhere (original tab, preferred tab)
// @instantCodes    pre-translate layer codes (hinted as instant)
// @showHints       show instant / first-view-takes-seconds hints
// @selectedCode    currently selected code (preference surfaces)
export default class BabelLanguagePicker extends Component {
  @tracked filter = "";

  get translatedCodes() {
    return this.args.translatedCodes || [];
  }

  get excludeCodes() {
    return (this.args.excludeCodes || []).filter(Boolean);
  }

  get instantCodes() {
    return this.args.instantCodes || [];
  }

  entriesFor(codes, { hinted = false } = {}) {
    const filter = this.filter.trim().toLowerCase();

    return codes
      .map((code) => {
        const name = languageEndonym(code);
        const localized = languageDisplayName(code);
        const entry = {
          code,
          name,
          // Only worth showing when it says something the endonym does not.
          secondary: localized === name ? null : localized,
          sortKey: localized,
        };

        if (code === this.args.sourceCode) {
          // The post's own language stays selectable so readers can override
          // a wrong detection; a right one just translates to itself once.
          entry.hint = i18n(
            "babel_reunited.language_tabs.source_language_hint"
          );
        } else if (
          hinted &&
          this.args.showHints &&
          this.instantCodes.includes(code)
        ) {
          // Only the exception is badged: the rule ("first view takes a few
          // seconds") is stated once above the list instead of on every row.
          entry.hint = i18n("babel_reunited.language_tabs.instant_hint");
        }
        return entry;
      })
      .filter((entry) => {
        if (!filter) {
          return true;
        }
        // Searchable by the language's own name, by its name in the viewer's
        // interface locale, and by code: a reader typing 中文 finds it
        // without knowing it is called "Chinese" here.
        return (
          entry.code.toLowerCase().includes(filter) ||
          entry.name.toLowerCase().includes(filter) ||
          (entry.secondary || "").toLowerCase().includes(filter)
        );
      })
      .sort((a, b) => a.sortKey.localeCompare(b.sortKey));
  }

  get translatedEntries() {
    return this.entriesFor(
      this.translatedCodes.filter((code) => !this.excludeCodes.includes(code))
    );
  }

  get otherEntries() {
    const skip = new Set([...this.translatedCodes, ...this.excludeCodes]);
    return this.entriesFor(
      SUPPORTED_LOCALES.filter((code) => !skip.has(code)),
      { hinted: true }
    );
  }

  @action
  updateFilter(event) {
    this.filter = event.target.value;
  }

  @action
  select(code) {
    // Picking the entry tagged as the source language is the one deliberate
    // way to ask for a same-language translation (when detection got it
    // wrong), so the caller is told which entry this was.
    this.args.onSelect?.(code, code === this.args.sourceCode);
  }

  <template>
    <div class="babel-language-picker">
      <input
        type="text"
        class="babel-language-picker__filter"
        placeholder={{i18n "babel_reunited.language_tabs.search_placeholder"}}
        value={{this.filter}}
        {{on "input" this.updateFilter}}
      />

      {{#if @showHints}}
        <div class="babel-language-picker__note">
          {{i18n "babel_reunited.language_tabs.on_demand_hint"}}
        </div>
      {{/if}}

      <div class="babel-language-picker__list">
        {{#if this.translatedEntries.length}}
          <div class="babel-language-picker__group-label">
            {{i18n "babel_reunited.language_tabs.translated_group"}}
          </div>
          {{#each this.translatedEntries as |entry|}}
            <button
              type="button"
              class={{concatClass
                "babel-language-picker__item --translated"
                (if (eq entry.code @selectedCode) "--selected")
              }}
              {{on "click" (fn this.select entry.code)}}
            >
              {{icon "check"}}
              <span class="babel-language-picker__name">{{entry.name}}</span>
              {{#if entry.secondary}}
                <span
                  class="babel-language-picker__secondary"
                >{{entry.secondary}}</span>
              {{/if}}
            </button>
          {{/each}}
        {{/if}}

        {{#if this.otherEntries.length}}
          {{#if this.translatedEntries.length}}
            <div class="babel-language-picker__group-label">
              {{i18n "babel_reunited.language_tabs.all_group"}}
            </div>
          {{/if}}
          {{#each this.otherEntries as |entry|}}
            <button
              type="button"
              class={{concatClass
                "babel-language-picker__item"
                (if (eq entry.code @selectedCode) "--selected")
              }}
              {{on "click" (fn this.select entry.code)}}
            >
              <span class="babel-language-picker__name">{{entry.name}}</span>
              {{#if entry.secondary}}
                <span
                  class="babel-language-picker__secondary"
                >{{entry.secondary}}</span>
              {{/if}}
              {{#if entry.hint}}
                <span class="babel-language-picker__hint">{{entry.hint}}</span>
              {{/if}}
            </button>
          {{/each}}
        {{/if}}
      </div>
    </div>
  </template>
}
