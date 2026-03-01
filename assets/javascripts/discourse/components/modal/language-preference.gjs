import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DModal from "discourse/components/d-modal";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import { getSupportedLanguages } from "../../lib/supported-languages";

export default class LanguagePreferenceModal extends Component {
  @service currentUser;
  @service siteSettings;

  @tracked saving = false;

  get languages() {
    return getSupportedLanguages(this.siteSettings);
  }

  @action
  async selectLanguage(language) {
    this.saving = true;

    try {
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { language },
      });

      this.currentUser.set("preferred_language", language);
      this.currentUser.set("preferred_language_enabled", true);
      localStorage.setItem("language_preference_modal_shown", "true");
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  async disableTranslation() {
    this.saving = true;

    try {
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { enabled: false },
      });

      this.currentUser.set("preferred_language_enabled", false);
      localStorage.setItem("language_preference_modal_shown", "true");
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  skip() {
    localStorage.setItem("language_preference_modal_shown", "true");
    this.args.closeModal();
  }

  <template>
    <DModal
      @inline={{@inline}}
      @closeModal={{this.skip}}
      @title={{i18n "babel_reunited.language_preference_modal.title"}}
      class="language-preference-modal"
    >
      <:body>
        <p>{{i18n "babel_reunited.language_preference_modal.description"}}</p>

        <div class="language-buttons">
          {{#each this.languages as |lang|}}
            <button
              class="language-btn"
              disabled={{this.saving}}
              {{on "click" (fn this.selectLanguage lang)}}
            >
              <span class="language-name">{{i18n
                  (concat "babel_reunited.language_tabs.languages." lang)
                  defaultValue=lang
                }}</span>
            </button>
          {{/each}}
        </div>

        <div class="disable-section">
          <div class="disable-text">
            {{i18n
              "babel_reunited.language_preference_modal.disable_description"
            }}
          </div>
          <button
            class="disable-btn"
            disabled={{this.saving}}
            {{on "click" this.disableTranslation}}
          >
            <span class="disable-label">{{i18n
                "babel_reunited.language_preference_modal.disable"
              }}</span>
          </button>
        </div>
      </:body>
    </DModal>
  </template>
}
