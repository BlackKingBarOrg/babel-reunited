import { withPluginApi } from "discourse/lib/plugin-api"
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference"

export default {
  initialize() {
    withPluginApi((api) => {
      const currentUser = api.getCurrentUser()

      if (!currentUser) {
        return
      }

      // Listen for MessageBus messages about language preference prompts
      api.onPageChange(() => {
        const messageBus = api.container.lookup("service:message-bus")
        const modal = api.container.lookup("service:modal")

        if (!messageBus || !modal) {
          return
        }

        // Subscribe to language preference prompt messages
        messageBus.subscribe(`/language-preference-prompt/${currentUser.id}`, (data) => {
          // Check if user already has a preferred language
          if (currentUser.user_preferred_language) {
            return
          }

          // Check if modal was already shown in this session
          const modalShown = sessionStorage.getItem("language_preference_modal_shown")
          if (modalShown) {
            return
          }

          // Show the modal after a short delay to ensure page is loaded
          setTimeout(() => {
            modal.show(LanguagePreferenceModal)
          }, 1000)
        })
      })

       // Also check on initial page load
       api.onPageChange(async () => {
         const currentUser = api.getCurrentUser()
         const modal = api.container.lookup("service:modal")

         if (!currentUser || !modal) {
           return
         }

         if (currentUser.preferred_language_enabled === false) {
           return
         }

         // Check if user already has a preferred language
         if (currentUser.preferred_language) {
           return
         }

         // Show the modal after a delay
         setTimeout(() => {
           modal.show(LanguagePreferenceModal)
         }, 1000)
       })
    })
  },
}
