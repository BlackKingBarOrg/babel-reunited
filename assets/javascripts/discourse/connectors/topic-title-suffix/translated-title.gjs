import Component from "@glimmer/component";

/**
 * Simple translated title component
 * Shows translated title if available, otherwise shows nothing
 */
export default class TranslatedTitleComponent extends Component {
  constructor() {
    super(...arguments);
  }

  get topic() {
    const topic = this.args.model || this.args.topic;
    return topic;
  }

  get translatedTitle() {
    const translatedTitle = this.topic?.babel_translated_title;
    return translatedTitle;
  }

  get shouldShowTranslatedTitle() {
    const shouldShow =
      this.topic &&
      this.translatedTitle &&
      this.translatedTitle !== this.topic.title &&
      this.translatedTitle.length > 0;
    return shouldShow;
  }

  get topicUrl() {
    return this.topic?.url;
  }

  <template>
    {{#if this.shouldShowTranslatedTitle}}
      <div
        class="ai-translated-title"
        style="margin-left: 8px; font-size: 14px; color: #666;"
      >
        <div class="translated-title-content">
          <a
            href={{this.topicUrl}}
            data-topic-id={{this.topic.id}}
            class="translated-title-link"
            style="font-weight: 500; color: #333; line-height: 1.3; text-decoration: none;"
          >
            {{this.translatedTitle}}
          </a>
        </div>
      </div>
    {{/if}}
  </template>
}
