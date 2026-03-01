import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import concatClass from "discourse/helpers/concat-class";
import icon from "discourse/helpers/d-icon";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { getSupportedLanguages } from "../../lib/supported-languages";

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
  @tracked _localTranslations = null;

  constructor() {
    super(...arguments);

    this.initializePreferredLanguage();

    this._messageBusChannel = `/post-translations/${this.post.id}`;
    this._onTranslationUpdate = (data) => {
      if (data.status === "completed" && data.translation) {
        this.updatePostTranslation(data.language, data.translation);
      }
      if (data.status === "failed") {
        this.handleTranslationFailure(data.language);
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

  get translations() {
    return this._localTranslations ?? this.post?.post_translations ?? [];
  }

  updatePostTranslation(language, translationData) {
    const existing = this.translations.filter(
      (t) => t.post_translation?.language !== language
    );
    this._localTranslations = [
      ...existing,
      { post_translation: translationData },
    ];
  }

  handleTranslationFailure(language) {
    const existing = this.translations.filter(
      (t) => t.post_translation?.language !== language
    );
    this._localTranslations = [
      ...existing,
      { post_translation: { language, status: "failed" } },
    ];
    if (this.currentLanguage === language) {
      this.currentLanguage = "original";
    }
  }

  get isAiTranslationDisabled() {
    return this.currentUser?.preferred_language_enabled === false;
  }

  initializePreferredLanguage() {
    if (this.isAiTranslationDisabled) {
      this.currentLanguage = "original";
      return;
    }

    if (!this.currentUser?.preferred_language) {
      return;
    }

    const preferredLanguage = this.currentUser.preferred_language;
    const translation = this.findTranslation(preferredLanguage);
    if (translation?.post_translation?.status === "completed") {
      this.currentLanguage = preferredLanguage;
    }
  }

  get post() {
    return this.args.post;
  }

  findTranslation(languageCode) {
    return this.translations.find(
      (t) => t.post_translation?.language === languageCode
    );
  }

  getTranslationStatus(languageCode) {
    return this.findTranslation(languageCode)?.post_translation?.status || "";
  }

  tabClass(languageCode) {
    if (this.currentLanguage === languageCode) {
      return "--active";
    }
    const status = this.getTranslationStatus(languageCode);
    if (status === "completed") {
      return "--completed";
    }
    return "--pending";
  }

  get availableLanguages() {
    return this.translations
      .map((t) => t.post_translation?.language)
      .filter(Boolean);
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
          status && status !== "completed" ? `${name} (${status})` : name,
      };
    });
  }

  get currentContent() {
    if (this.currentLanguage === "original") {
      return this.post?.cooked || this.post?.raw || "";
    }

    const translation = this.findTranslation(this.currentLanguage);
    const content = translation?.post_translation?.translated_content;
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

    const status = this.getTranslationStatus(languageCode);
    if (status === "completed") {
      this.currentLanguage = languageCode;
    } else {
      this.currentLanguage = "original";
    }
  }

  <template>
    {{#if this.isAiTranslationDisabled}}
      <div class="babel-reunited-disabled-notice">
        {{i18n "babel_reunited.language_tabs.disabled_by_user"}}
      </div>
    {{else}}
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
              {{icon "spinner"}}
            {{/if}}
          </button>
        {{/each}}
      </div>
    {{/if}}

    <div class="cooked">
      {{htmlSafe this.currentContent}}
    </div>
  </template>
}
