import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import PostCookedHtml from "discourse/components/post/cooked-html";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line simple-import-sort/imports, discourse/ui-kit-imports
import concatClass from "discourse/helpers/concat-class";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { getSupportedLanguages } from "../../lib/supported-languages";

const DISPLAYABLE_STATUSES = ["completed", "stale"];

export default class LanguageTabsConnector extends Component {
  static getLanguageDisplayName(code) {
    return i18n(`babel_reunited.language_tabs.languages.${code}`, {
      defaultValue: code,
    });
  }

  @service currentUser;
  @service messageBus;
  @service siteSettings;

  @tracked currentLanguage = "original";
  @tracked _states = null;
  @tracked _pendingLanguage = null;

  constructor() {
    super(...arguments);

    this._staleRefreshRequested = new Set();

    this.initializePreferredLanguage();

    this._messageBusChannel = `/post-translations/${this.post.id}`;
    this._onTranslationUpdate = (data) => {
      if (data.status === "completed" && data.translation) {
        this.mergeState(data.language, {
          ...data.translation,
          status: "completed",
        });
        if (this._pendingLanguage === data.language) {
          this.currentLanguage = data.language;
          this._pendingLanguage = null;
        }
      }
      if (data.status === "failed") {
        this.mergeState(data.language, { status: "failed" });
        if (this._pendingLanguage === data.language) {
          this._pendingLanguage = null;
        }
        if (this.currentLanguage === data.language) {
          this.currentLanguage = "original";
        }
      }
    };

    this.messageBus?.subscribe(
      this._messageBusChannel,
      this._onTranslationUpdate
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.messageBus?.unsubscribe(
      this._messageBusChannel,
      this._onTranslationUpdate
    );
  }

  // language -> { language, status, source_language, translated_content?, ... }
  // Metadata for every translation comes from babel_translations_meta; the
  // body is serialized only for the viewer's preferred language and merged in
  // lazily for other languages (show endpoint or MessageBus payloads).
  get states() {
    if (this._states) {
      return this._states;
    }

    const map = {};
    for (const meta of this.post?.babel_translations_meta || []) {
      if (meta?.language) {
        map[meta.language] = { ...meta };
      }
    }

    const preferred = this.post?.babel_preferred_translation;
    if (preferred?.language) {
      map[preferred.language] = { ...map[preferred.language], ...preferred };
    }

    return map;
  }

  mergeState(language, attrs) {
    const next = { ...this.states };
    next[language] = { ...next[language], language, ...attrs };
    this._states = next;
  }

  removeState(language) {
    const next = { ...this.states };
    delete next[language];
    this._states = next;
  }

  get isAiTranslationDisabled() {
    return this.currentUser?.preferred_language_enabled === false;
  }

  get translationEnabledForCategory() {
    const allowedRaw = this.siteSettings.babel_reunited_enabled_categories;
    if (!allowedRaw) {
      return true;
    }
    const allowedIds = allowedRaw.split("|").map(Number);
    const categoryId = this.post?.topic?.category_id ?? this.post?.category_id;
    return categoryId ? allowedIds.includes(categoryId) : false;
  }

  initializePreferredLanguage() {
    if (this.isAiTranslationDisabled) {
      this.currentLanguage = "original";
      return;
    }

    if (!this.translationEnabledForCategory) {
      return;
    }

    if (!this.currentUser?.preferred_language) {
      return;
    }

    const preferredLanguage = this.currentUser.preferred_language;
    if (this._hasDisplayableContent(preferredLanguage)) {
      this.currentLanguage = preferredLanguage;
    }
  }

  isDisplayableStatus(status) {
    return DISPLAYABLE_STATUSES.includes(status);
  }

  _hasDisplayableContent(languageCode) {
    const state = this.states[languageCode];
    return !!(
      state &&
      this.isDisplayableStatus(state.status) &&
      state.translated_content
    );
  }

  get post() {
    return this.args.post;
  }

  getTranslationStatus(languageCode) {
    return this.states[languageCode]?.status || "";
  }

  tabClass(languageCode) {
    if (this.currentLanguage === languageCode) {
      return "--active";
    }
    const status = this.getTranslationStatus(languageCode);
    if (this.isDisplayableStatus(status)) {
      return "--completed";
    }
    return "--pending";
  }

  get availableLanguages() {
    return Object.keys(this.states);
  }

  get languageNames() {
    const supportedLanguages = getSupportedLanguages(this.siteSettings);

    return supportedLanguages.map((code) => {
      const name = LanguageTabsConnector.getLanguageDisplayName(code);
      const available = this.availableLanguages.includes(code);
      const status = this.getTranslationStatus(code);

      return {
        code,
        name,
        available,
        status,
        tabClass: this.tabClass(code),
        displayText:
          status && !this.isDisplayableStatus(status)
            ? `${name} (${status})`
            : name,
      };
    });
  }

  get currentContent() {
    if (this.currentLanguage === "original") {
      return this.post?.cooked || this.post?.raw || "";
    }

    const content = this.states[this.currentLanguage]?.translated_content;
    return content || this.post?.cooked || "";
  }

  get currentLanguageName() {
    if (this.currentLanguage === "original") {
      return i18n("babel_reunited.language_tabs.original");
    }
    return LanguageTabsConnector.getLanguageDisplayName(this.currentLanguage);
  }

  @action
  switchLanguage(languageCode) {
    if (languageCode === "original") {
      this.currentLanguage = languageCode;
      return;
    }

    if (this._hasDisplayableContent(languageCode)) {
      this.currentLanguage = languageCode;
      if (this.getTranslationStatus(languageCode) === "stale") {
        this._refreshStaleTranslation(languageCode);
      }
      return;
    }

    const status = this.getTranslationStatus(languageCode);
    if (this.isDisplayableStatus(status)) {
      // The body exists server-side but was not serialized; fetch it.
      this._fetchTranslation(languageCode);
    } else if (
      status !== "translating" &&
      this._pendingLanguage !== languageCode
    ) {
      this._requestTranslation(languageCode);
    }
  }

  async _fetchTranslation(languageCode) {
    try {
      const json = await ajax(
        `/babel-reunited/posts/${this.post.id}/translations/${encodeURIComponent(
          languageCode
        )}.json`
      );
      const data = json?.post_translation || json;
      if (data?.language) {
        this.mergeState(languageCode, data);
        this.currentLanguage = languageCode;
        if (data.status === "stale") {
          this._refreshStaleTranslation(languageCode);
        }
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  // Stale content stays on screen; the fresh translation swaps in through the
  // regular MessageBus completion. Errors stay silent because the reader
  // already has readable (old) content.
  async _refreshStaleTranslation(languageCode) {
    if (this._staleRefreshRequested.has(languageCode)) {
      return;
    }
    this._staleRefreshRequested.add(languageCode);

    try {
      await ajax(`/babel-reunited/posts/${this.post.id}/translations`, {
        type: "POST",
        data: { target_language: languageCode },
      });
    } catch {
      // best-effort refresh
    }
  }

  async _requestTranslation(languageCode) {
    this._pendingLanguage = languageCode;

    const previous = this.states[languageCode];
    this.mergeState(languageCode, { status: "translating" });

    try {
      await ajax(`/babel-reunited/posts/${this.post.id}/translations`, {
        type: "POST",
        data: { target_language: languageCode },
      });
    } catch (error) {
      this._pendingLanguage = null;
      if (previous) {
        this.mergeState(languageCode, previous);
      } else {
        this.removeState(languageCode);
      }
      popupAjaxError(error);
    }
  }

  <template>
    {{#if this.isAiTranslationDisabled}}
      <div class="babel-reunited-disabled-notice">
        {{i18n "babel_reunited.language_tabs.disabled_by_user"}}
      </div>
    {{else if this.translationEnabledForCategory}}
      <div class="ai-language-tabs">
        <button
          class={{concatClass
            "babel-reunited-language-tab"
            (if (eq this.currentLanguage "original") "--active")
          }}
          {{on "click" (fn this.switchLanguage "original")}}
        >
          {{i18n "babel_reunited.language_tabs.original"}}
        </button>

        {{#each this.languageNames as |langInfo|}}
          <button
            class={{concatClass
              "babel-reunited-language-tab"
              langInfo.tabClass
            }}
            {{on "click" (fn this.switchLanguage langInfo.code)}}
            title={{if
              langInfo.available
              (i18n
                "babel_reunited.language_tabs.switch_to" language=langInfo.name
              )
              (i18n
                "babel_reunited.language_tabs.start_translation"
                language=langInfo.name
              )
            }}
          >
            {{langInfo.name}}
            {{#if (eq langInfo.status "translating")}}
              <div class="spinner small"></div>
            {{/if}}
          </button>
        {{/each}}
      </div>
    {{/if}}

    {{#if (eq this.currentLanguage "original")}}
      {{! Core's own PostCookedHtml, passed in as the outlet's default block:
          identical rendering and decoration to a Babel-less install }}
      {{yield}}
    {{else}}
      <PostCookedHtml
        @post={{this.post}}
        @cooked={{this.currentContent}}
        @decoratorState={{@decoratorState}}
      />
    {{/if}}
  </template>
}
