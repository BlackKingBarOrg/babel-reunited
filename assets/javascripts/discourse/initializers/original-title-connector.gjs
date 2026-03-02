import Component from "@glimmer/component";
import { apiInitializer } from "discourse/lib/api";

export default apiInitializer((api) => {
  const settings = api.container.lookup("service:site-settings");

  if (!settings.babel_reunited_enabled) {
    return;
  }

  const OUTLETS = {
    desktop: "topic-list-topic-cell-link-bottom-line__before",
    mobile: "topic-list-main-link-bottom",
  };

  function renderOriginalTitleInOutlet(outletName, shouldRenderFn) {
    api.renderInOutlet(
      outletName,
      class extends Component {
        static shouldRender(args, context) {
          if (!shouldRenderFn(context)) {
            return false;
          }

          return (
            args.topic?.fancy_title_localized || args.topic?.fancyTitleLocalized
          );
        }

        <template>
          <span class="topic-list-item-original-title">
            {{@outletArgs.topic.title}}
          </span>
        </template>
      }
    );
  }

  renderOriginalTitleInOutlet(
    OUTLETS.desktop,
    (context) => context.site.desktopView
  );
  renderOriginalTitleInOutlet(
    OUTLETS.mobile,
    (context) => context.site.mobileView
  );
});
