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
  @tracked _detectedLocale = null;

  constructor() {
    super(...arguments);

    this._staleRefreshRequested = new Set();

    this.initializePreferredLanguage();

    this._messageBusChannel = `/post-translations/${this.post.id}`;
    this._onTranslationUpdate = (data) => {
      if (data.detected_locale) {
        // Detection finished after this page rendered; adopting it drops any
        // tab offering to translate the post into its own language.
        this.applyDetectedLocale(data.detected_locale);
        return;
      }
      if (data.status === "completed" && data.translation) {
        // The payload status can be "stale" when the post changed while the
        // translation ran; the content is readable and a refresh follows.
        this.mergeState(data.language, {
          ...data.translation,
          status: data.translation.status || "completed",
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

    // A translation into the post's own language is redundant — the original
    // view already is that language. Such a record outlives a rewrite as
    // permanently stale content that nothing will refresh, so it must never
    // be selectable. Requesting it explicitly still works (detection can be
    // wrong): that merges a fresh record into _states.
    if (this.detectedLocale) {
      delete map[this.detectedLocale];
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

    // preferredCode, not the raw preference: when the post is already in the
    // reader's language the original tab covers it.
    const preferredLanguage = this.preferredCode;
    if (preferredLanguage && this._hasDisplayableContent(preferredLanguage)) {
      this.currentLanguage = preferredLanguage;
    }
  }

  isDisplayableStatus(status) {
    return DISPLAYABLE_STATUSES.includes(status);
  }

  // Anything with a body that is not failed is readable — including a record
  // currently re-translating, whose old body stays on screen until the fresh
  // one swaps in.
  _hasDisplayableContent(languageCode) {
    const state = this.states[languageCode];
    return !!(state && state.status !== "failed" && state.translated_content);
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
    return this._detectedLocale ?? this.post?.babel_detected_locale ?? null;
  }

  // Detection can land (or be corrected by the server) after render, so it is
  // tracked separately from the serialized value.
  applyDetectedLocale(locale) {
    if (!locale || this.detectedLocale === locale) {
      return;
    }

    this._detectedLocale = locale;
    if (this.currentLanguage === locale) {
      // Whatever was on screen for that language is the post's own content.
      this.currentLanguage = "original";
    }
    if (this._pendingLanguage === locale) {
      this._pendingLanguage = null;
    }
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
    return [this.preferredCode];
  }

  get instantCodes() {
    return getSupportedLanguages(this.siteSettings);
  }

  @action
  pickLanguage(closeFn, code, isSourceLanguage = false) {
    closeFn?.();
    this.switchLanguage(code, { overrideSource: isSourceLanguage });
  }

  get currentContent() {
    if (this.currentLanguage === "original") {
      return this.post?.cooked || this.post?.raw || "";
    }

    const content = this.states[this.currentLanguage]?.translated_content;
    return content || this.post?.cooked || "";
  }

  // Shown above translated content whose source post has changed (stale) or
  // which is being refreshed right now.
  get viewingNotice() {
    if (this.currentLanguage === "original") {
      return null;
    }

    const state = this.states[this.currentLanguage];
    if (!state?.translated_content) {
      return null;
    }

    if (state.status === "stale") {
      return i18n("babel_reunited.language_tabs.stale_notice");
    }
    if (state.status === "translating") {
      return i18n("babel_reunited.language_tabs.refreshing_notice");
    }
    return null;
  }

  get currentLanguageName() {
    if (this.currentLanguage === "original") {
      return i18n("babel_reunited.language_tabs.original");
    }
    return languageDisplayName(this.currentLanguage);
  }

  @action
  switchLanguage(languageCode, { overrideSource = false } = {}) {
    // Any deliberate switch supersedes whatever the reader was waiting for,
    // so a late async response cannot override this newer choice.
    if (languageCode === "original") {
      this._pendingLanguage = null;
      this.currentLanguage = languageCode;
      return;
    }

    if (this._hasDisplayableContent(languageCode)) {
      this._pendingLanguage = null;
      this.currentLanguage = languageCode;
      if (this.getTranslationStatus(languageCode) === "stale") {
        this._refreshStaleTranslation(languageCode);
      }
      return;
    }

    const status = this.getTranslationStatus(languageCode);
    if (status && status !== "failed") {
      this._pendingLanguage = languageCode;
      // A record exists server-side (completed, stale, or re-translating with
      // an old body) but the body is not local; fetch it. Fresh translating
      // rows come back empty and simply keep their spinner.
      this._fetchTranslation(languageCode);
    } else if (this._pendingLanguage !== languageCode) {
      this._requestTranslation(languageCode, { overrideSource });
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
        // The reader may have moved on while this was in flight.
        if (
          data.translated_content &&
          this._pendingLanguage === languageCode
        ) {
          this._pendingLanguage = null;
          this.currentLanguage = languageCode;
          if (data.status === "stale") {
            this._refreshStaleTranslation(languageCode);
          }
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

  async _requestTranslation(languageCode, { overrideSource = false } = {}) {
    this._pendingLanguage = languageCode;

    const previous = this.states[languageCode];
    this.mergeState(languageCode, { status: "translating" });

    try {
      const data = { target_language: languageCode };
      if (overrideSource) {
        data.override_source = true;
      }

      const result = await ajax(
        `/babel-reunited/posts/${this.post.id}/translations`,
        { type: "POST", data }
      );

      if (result?.reason === "source_language") {
        // Our detection data was stale: the post is already in this
        // language. Adopt the server's answer and drop the optimistic state.
        if (previous) {
          this.mergeState(languageCode, previous);
        } else {
          this.removeState(languageCode);
        }
        this.applyDetectedLocale(result.detected_locale || languageCode);
        this.currentLanguage = "original";
        return;
      }
    } catch (error) {
      // Only retract our own claim: a failure here must not cancel a later
      // request the reader is still waiting on.
      if (this._pendingLanguage === languageCode) {
        this._pendingLanguage = null;
      }
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
            @sourceCode={{this.detectedLocale}}
            @showHints={{true}}
            @onSelect={{fn this.pickLanguage menu.close}}
          />
        </DMenu>
      </div>
    {{/if}}

    {{#if this.viewingNotice}}
      <div class="babel-reunited-stale-notice">{{this.viewingNotice}}</div>
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
