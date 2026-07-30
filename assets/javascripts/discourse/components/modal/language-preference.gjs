import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line discourse/ui-kit-imports
import DModal from "discourse/components/d-modal";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import { getSupportedLanguages } from "../../lib/supported-languages";
import BabelLanguagePicker from "../babel-language-picker";

export default class LanguagePreferenceModal extends Component {
  @service currentUser;
  @service siteSettings;

  @tracked saving = false;

  get instantCodes() {
    return getSupportedLanguages(this.siteSettings);
  }

  get modalDescription() {
    return trustHTML(
      this.siteSettings.babel_reunited_modal_description ||
        i18n("babel_reunited.language_preference_modal.description")
    );
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

  <template>
    <DModal
      @inline={{@inline}}
      @closeModal={{@closeModal}}
      @title={{i18n "babel_reunited.language_preference_modal.title"}}
      class="language-preference-modal"
    >
      <:body>
        <p>{{this.modalDescription}}</p>

        <BabelLanguagePicker
          @instantCodes={{this.instantCodes}}
          @showHints={{true}}
          @onSelect={{this.selectLanguage}}
        />

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
