import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { cancel } from "@ember/runloop";
import { service } from "@ember/service";
import PostCookedHtml from "discourse/components/post/cooked-html";
import DMenu from "discourse/float-kit/components/d-menu";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line discourse/ui-kit-imports
import concatClass from "discourse/helpers/concat-class";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import discourseLater from "discourse/lib/later";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import BabelLanguagePicker from "../../components/babel-language-picker";
import { languageDisplayName } from "../../lib/language-display-name";
import { getSupportedLanguages } from "../../lib/supported-languages";

const DISPLAYABLE_STATUSES = ["completed", "stale"];

// Posts scrolled past render transiently (cloaking); only posts the reader
// dwells on for this long fire an automatic translation request.
const VIEW_TRIGGER_DWELL_MS = 500;

// Session-level dedup: cloak/uncloak cycles recreate the component, but one
// (post, language) pair should only ever fire one automatic request.
const viewTriggerAttempted = new Set();

export default class LanguageTabsConnector extends Component {
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

    this._viewTriggerTimer = discourseLater(
      this,
      this._maybeViewTrigger,
      VIEW_TRIGGER_DWELL_MS
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this._viewTriggerTimer);
    this.messageBus?.unsubscribe(
      this._messageBusChannel,
      this._onTranslationUpdate
    );
  }

  _maybeViewTrigger() {
    if (this.isDestroying || this.isDestroyed) {
      return;
    }
    if (!this.siteSettings.babel_reunited_view_triggered_translation) {
      return;
    }
    if (this.isAiTranslationDisabled || !this.translationEnabledForCategory) {
      return;
    }

    const preferred = this.currentUser?.preferred_language;
    if (!preferred) {
      return;
    }
    if (this.post?.babel_detected_locale === preferred) {
      return;
    }

    // Missing, stale, or failed records go to the server, which owns the
    // retry/dedup/fuse policy; fresh or in-flight ones never leave the client.
    const status = this.getTranslationStatus(preferred);
    if (status === "translating" || status === "completed") {
      return;
    }

    const key = `${this.post.id}:${preferred}`;
    if (viewTriggerAttempted.has(key)) {
      return;
    }
    viewTriggerAttempted.add(key);

    this._sendViewTrigger(preferred);
  }

  async _sendViewTrigger(languageCode) {
    try {
      const response = await ajax(
        `/babel-reunited/posts/${this.post.id}/translations`,
        {
          type: "POST",
          data: { target_language: languageCode, trigger: "view" },
        }
      );

      if (response?.status === "queued") {
        const state = this.states[languageCode];
        if (!state || !this.isDisplayableStatus(state.status)) {
          // No readable content yet: show the translating hint and switch
          // once the completion arrives.
          this.mergeState(languageCode, { status: "translating" });
          this._pendingLanguage = languageCode;
        }
        // Stale content stays on screen; the refresh swaps in silently.
      }
    } catch {
      // The automated lane never surfaces errors: the reader still has the
      // original content, and manual requests keep their own error popups.
    }
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

  get detectedLocale() {
    return this.post?.babel_detected_locale || null;
  }

  get originalTabLabel() {
    if (this.detectedLocale) {
      return i18n("babel_reunited.language_tabs.original_with_language", {
        language: languageDisplayName(this.detectedLocale),
      });
    }
    return i18n("babel_reunited.language_tabs.original");
  }

  // The preferred language gets its own fixed tab — unless it IS the post's
  // language, in which case the original tab covers it.
  get preferredCode() {
    const code = this.currentUser?.preferred_language;
    if (!code || code === this.detectedLocale) {
      return null;
    }
    return code;
  }

  get preferredTab() {
    const code = this.preferredCode;
    if (!code) {
      return null;
    }

    const status = this.getTranslationStatus(code);
    const name = languageDisplayName(code);
    let title;
    if (status === "failed") {
      title = i18n("babel_reunited.language_tabs.failed_retry");
    } else if (this._hasDisplayableContent(code)) {
      title = i18n("babel_reunited.language_tabs.switch_to", {
        language: name,
      });
    } else {
      title = i18n("babel_reunited.language_tabs.start_translation", {
        language: name,
      });
    }

    return {
      code,
      name,
      status,
      failed: status === "failed",
      translating: status === "translating",
      tabClass: this.tabClass(code),
      title,
    };
  }

  // A language picked from the overflow menu shows as a transient tab so the
  // reader can see what they are looking at and switch back.
  get ephemeralTab() {
    let code = null;
    if (
      this.currentLanguage !== "original" &&
      this.currentLanguage !== this.preferredCode
    ) {
      code = this.currentLanguage;
    } else if (
      this._pendingLanguage &&
      this._pendingLanguage !== this.preferredCode
    ) {
      code = this._pendingLanguage;
    }

    if (!code) {
      return null;
    }

    return {
      code,
      name: languageDisplayName(code),
      status: this.getTranslationStatus(code),
      tabClass: this.tabClass(code),
    };
  }

  get translatedCodes() {
    return this.availableLanguages.filter((code) =>
      this.isDisplayableStatus(this.states[code]?.status)
    );
  }

  get pickerExcludeCodes() {
    return [this.detectedLocale, this.preferredCode];
  }

  get instantCodes() {
    return getSupportedLanguages(this.siteSettings);
  }

  @action
  pickLanguage(closeFn, code) {
    closeFn?.();
    this.switchLanguage(code);
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
    return languageDisplayName(this.currentLanguage);
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
          {{this.originalTabLabel}}
        </button>

        {{#if this.preferredTab}}
          <button
            class={{concatClass
              "babel-reunited-language-tab"
              this.preferredTab.tabClass
              (if this.preferredTab.failed "--failed")
            }}
            title={{this.preferredTab.title}}
            {{on "click" (fn this.switchLanguage this.preferredTab.code)}}
          >
            {{this.preferredTab.name}}
            {{#if this.preferredTab.translating}}
              <div class="spinner small"></div>
            {{/if}}
            {{#if this.preferredTab.failed}}
              <span class="babel-reunited-retry-hint">
                {{i18n "babel_reunited.language_tabs.retry"}}
              </span>
            {{/if}}
          </button>
        {{/if}}

        {{#if this.ephemeralTab}}
          <button
            class={{concatClass
              "babel-reunited-language-tab"
              this.ephemeralTab.tabClass
            }}
            {{on "click" (fn this.switchLanguage this.ephemeralTab.code)}}
          >
            {{this.ephemeralTab.name}}
            {{#if (eq this.ephemeralTab.status "translating")}}
              <div class="spinner small"></div>
            {{/if}}
          </button>
        {{/if}}

        <DMenu
          class="babel-reunited-language-tab --menu btn-flat"
          @identifier="babel-language-menu"
          @icon="globe"
          @title={{i18n "babel_reunited.language_tabs.more_languages"}}
          @modalForMobile={{true}}
          as |menu|
        >
          <BabelLanguagePicker
            @translatedCodes={{this.translatedCodes}}
            @excludeCodes={{this.pickerExcludeCodes}}
            @instantCodes={{this.instantCodes}}
            @showHints={{true}}
            @onSelect={{fn this.pickLanguage menu.close}}
          />
        </DMenu>
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
