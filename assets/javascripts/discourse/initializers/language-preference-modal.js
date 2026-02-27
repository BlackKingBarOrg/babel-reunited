import { withPluginApi } from "discourse/lib/plugin-api";
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference";

export default {
  initialize() {
    withPluginApi((api) => {
      const currentUser = api.getCurrentUser();

      if (!currentUser) {
        return;
      }

      const messageBus = api.container.lookup("service:message-bus");
      const modal = api.container.lookup("service:modal");

      if (!modal) {
        return;
      }

      let pendingModalTimeoutId = null;

      const scheduleModalShow = () => {
        if (currentUser.preferred_language_enabled === false) {
          return;
        }

        if (
          currentUser.user_preferred_language ||
          currentUser.preferred_language
        ) {
          return;
        }

        const modalShown = sessionStorage.getItem(
          "language_preference_modal_shown"
        );
        if (modalShown) {
          return;
        }

        if (pendingModalTimeoutId) {
          clearTimeout(pendingModalTimeoutId);
        }

        pendingModalTimeoutId = setTimeout(() => {
          modal.show(LanguagePreferenceModal);
          pendingModalTimeoutId = null;
        }, 1000);
      };

      if (messageBus) {
        messageBus.subscribe(
          `/language-preference-prompt/${currentUser.id}`,
          () => {
            scheduleModalShow();
          }
        );
      }

      api.onPageChange(() => {
        if (pendingModalTimeoutId) {
          clearTimeout(pendingModalTimeoutId);
          pendingModalTimeoutId = null;
        }

        scheduleModalShow();
      });
    });
  },
};
