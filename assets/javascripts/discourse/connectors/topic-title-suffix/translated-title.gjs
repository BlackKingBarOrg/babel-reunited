import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";

/**
 * Shows the translated topic title next to the original, if one exists.
 *
 * The serialized title is a snapshot: when the first post is translated while
 * the topic is open, the body swaps in over MessageBus but the title would
 * stay in the original language until a reload. Subscribing keeps the two in
 * step.
 */
export default class TranslatedTitleComponent extends Component {
  @service currentUser;
  @service messageBus;

  @tracked liveTitle = null;

  constructor() {
    super(...arguments);

    const topicId = this.topic?.id;
    if (!topicId) {
      return;
    }

    this._channel = `/babel-translated-title/${topicId}`;
    this._onTitle = (data) => {
      // Only the reader's own language may replace what they are looking at.
      if (data?.language === this.currentUser?.preferred_language) {
        this.liveTitle = data.translated_title;
      }
    };

    this.messageBus?.subscribe(this._channel, this._onTitle);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    if (this._channel) {
      this.messageBus?.unsubscribe(this._channel, this._onTitle);
    }
  }

  get topic() {
    return this.args.model || this.args.topic;
  }

  get translatedTitle() {
    return this.liveTitle ?? this.topic?.babel_translated_title;
  }

  get shouldShowTranslatedTitle() {
    const translated = this.translatedTitle;
    return !!(
      this.topic &&
      translated &&
      translated !== this.topic.title &&
      translated.length > 0
    );
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
