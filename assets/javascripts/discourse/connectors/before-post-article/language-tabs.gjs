import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import PostCookedHtml from "discourse/components/post/cooked-html";
import DMenu from "discourse/float-kit/components/d-menu";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line discourse/ui-kit-imports
import concatClass from "discourse/helpers/concat-class";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import BabelLanguagePicker from "../../components/babel-language-picker";
import { sameLanguage } from "../../lib/babel-locales";
import { languageEndonym } from "../../lib/language-display-name";
import { getSupportedLanguages } from "../../lib/supported-languages";
import BabelViewDwell from "../../modifiers/babel-view-dwell";

const DISPLAYABLE_STATUSES = ["completed", "stale"];

// How long a post must stay visible before it counts as read. The post
// stream uncloaks a full viewport beyond what is on screen, so being
// rendered proves nothing; only intersection held this long does.
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
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.messageBus?.unsubscribe(
      this._messageBusChannel,
      this._onTranslationUpdate
    );
  }

  @action
  maybeViewTrigger() {
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
    if (sameLanguage(this.post?.babel_detected_locale, preferred)) {
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
          // once the completion arrives — unless the reader made or
          // requested a different choice while this response was in flight.
          this.mergeState(languageCode, { status: "translating" });
          if (this.currentLanguage === "original" && !this._pendingLanguage) {
            this._pendingLanguage = languageCode;
          }
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
    if (sameLanguage(this.currentLanguage, locale)) {
      // Whatever was on screen for that language is the post's own content.
      this.currentLanguage = "original";
    }
    if (sameLanguage(this._pendingLanguage, locale)) {
      this._pendingLanguage = null;
    }
  }

  get originalTabLabel() {
    if (this.detectedLocale) {
      return i18n("babel_reunited.language_tabs.original_with_language", {
        language: languageEndonym(this.detectedLocale),
      });
    }
    return i18n("babel_reunited.language_tabs.original");
  }

  // The preferred language gets its own fixed tab — unless it IS the post's
  // language, in which case the original tab covers it.
  get preferredCode() {
    const code = this.currentUser?.preferred_language;
    if (!code || sameLanguage(code, this.detectedLocale)) {
      return null;
    }
    return code;
  }

  // The pre-translate layer stays as fixed tabs: unlike the set of translated
  // languages it is bounded by cost, so an admin keeps it small, and readers
  // coming from the old three-button UI find the same buttons. The reader's
  // own language leads when it is not already one of them, and the post's own
  // language never appears — the original tab is that language.
  get languageTabs() {
    const codes = [];
    if (this.preferredCode && !this.instantCodes.includes(this.preferredCode)) {
      codes.push(this.preferredCode);
    }
    for (const code of this.instantCodes) {
      if (!sameLanguage(code, this.detectedLocale) && !codes.includes(code)) {
        codes.push(code);
      }
    }
    return codes.map((code) => this.tabFor(code));
  }

  tabFor(code) {
    const status = this.getTranslationStatus(code);
    const name = languageEndonym(code);
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
    const fixed = this.languageTabs.map((tab) => tab.code);
    let code = null;
    if (
      this.currentLanguage !== "original" &&
      !fixed.includes(this.currentLanguage)
    ) {
      code = this.currentLanguage;
    } else if (
      this._pendingLanguage &&
      !fixed.includes(this._pendingLanguage)
    ) {
      code = this._pendingLanguage;
    }

    if (!code) {
      return null;
    }

    return {
      code,
      name: languageEndonym(code),
      status: this.getTranslationStatus(code),
      tabClass: this.tabClass(code),
    };
  }

  get translatedCodes() {
    return this.availableLanguages.filter((code) =>
      this.isDisplayableStatus(this.states[code]?.status)
    );
  }

  // Languages that already have their own tab need no menu entry.
  get pickerExcludeCodes() {
    return this.languageTabs.map((tab) => tab.code);
  }

  get instantCodes() {
    return getSupportedLanguages(this.siteSettings);
  }

  @action
  pickLanguage(closeFn, code, isSourceLanguage = false) {
    closeFn?.();
    // Asking for the language the post is already written in is a request to
    // read it in that language, and the original already is: show it rather
    // than paying to translate the post into itself.
    this.switchLanguage(isSourceLanguage ? "original" : code);
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
    return languageEndonym(this.currentLanguage);
  }

  @action
  switchLanguage(languageCode) {
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

    // No readable content locally. The show endpoint only ever returns
    // completed bodies, so what happens next depends on the row's state:
    // fetch a body that exists, wait out a run already in flight, and ask
    // the server to (re)translate everything else — stale, failed, missing.
    const status = this.getTranslationStatus(languageCode);
    if (status === "completed") {
      this._pendingLanguage = languageCode;
      this._fetchTranslation(languageCode);
    } else if (status === "translating") {
      this._pendingLanguage = languageCode;
    } else if (this._pendingLanguage !== languageCode) {
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

  async _requestTranslation(languageCode) {
    this._pendingLanguage = languageCode;

    const previous = this.states[languageCode];
    this.mergeState(languageCode, { status: "translating" });

    try {
      const result = await ajax(
        `/babel-reunited/posts/${this.post.id}/translations`,
        { type: "POST", data: { target_language: languageCode } }
      );

      if (result?.reason === "source_language") {
        // Our detection data was stale: the post is already in this
        // language. Adopt the server's answer and drop the optimistic state.
        const stillWaiting = this._pendingLanguage === languageCode;
        if (previous) {
          this.mergeState(languageCode, previous);
        } else {
          this.removeState(languageCode);
        }
        this.applyDetectedLocale(result.detected_locale || languageCode);
        // Only move the reader if they are still waiting on this request; by
        // now they may have picked another language.
        if (stillWaiting) {
          this._pendingLanguage = null;
          this.currentLanguage = "original";
        }
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
      <div
        class="ai-language-tabs"
        {{BabelViewDwell this.maybeViewTrigger dwellMs=VIEW_TRIGGER_DWELL_MS}}
      >
        <button
          class={{concatClass
            "babel-reunited-language-tab"
            (if (eq this.currentLanguage "original") "--active")
          }}
          {{on "click" (fn this.switchLanguage "original")}}
        >
          {{this.originalTabLabel}}
        </button>

        {{#each this.languageTabs as |tab|}}
          <button
            class={{concatClass
              "babel-reunited-language-tab"
              tab.tabClass
              (if tab.failed "--failed")
            }}
            title={{tab.title}}
            {{on "click" (fn this.switchLanguage tab.code)}}
          >
            {{tab.name}}
            {{#if tab.translating}}
              <div class="spinner small"></div>
            {{/if}}
            {{#if tab.failed}}
              <span class="babel-reunited-retry-hint">
                {{i18n "babel_reunited.language_tabs.retry"}}
              </span>
            {{/if}}
          </button>
        {{/each}}

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
