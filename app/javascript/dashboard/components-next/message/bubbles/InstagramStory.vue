<script setup>
import { ref, computed } from 'vue';
import { useMessageContext } from '../provider.js';
import Icon from 'next/icon/Icon.vue';
import BaseBubble from 'next/message/bubbles/Base.vue';

import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import { MESSAGE_VARIANTS } from '../constants';

const emit = defineEmits(['error']);
const { variant, content, attachments, contentAttributes } =
  useMessageContext();

// For story replies, the URL is in contentAttributes.storyUrl
// For story mentions, it's in attachments[0].dataUrl
const mediaUrl = computed(() => {
  // Story reply: URL is stored in contentAttributes
  if (contentAttributes.value?.storyUrl) {
    return contentAttributes.value.storyUrl;
  }
  // Story mention: URL is in attachment
  return attachments.value?.[0]?.dataUrl;
});

const hasImgStoryError = ref(false);
const hasVideoStoryError = ref(false);

const formattedContent = computed(() => {
  if (variant.value === MESSAGE_VARIANTS.ACTIVITY) {
    return content.value;
  }

  return new MessageFormatter(content.value).formattedMessage;
});

const onImageLoadError = () => {
  hasImgStoryError.value = true;
  emit('error');
};

const onVideoLoadError = () => {
  hasVideoStoryError.value = true;
  emit('error');
};
</script>

<template>
  <BaseBubble class="p-3 overflow-hidden" data-bubble-name="ig-story">
    <div v-if="content" v-dompurify-html="formattedContent" class="mb-2" />
    <img
      v-if="!hasImgStoryError && mediaUrl"
      class="rounded-lg max-w-80 skip-context-menu"
      :src="mediaUrl"
      @error="onImageLoadError"
    />
    <video
      v-else-if="!hasVideoStoryError && mediaUrl"
      class="rounded-lg max-w-80 skip-context-menu"
      controls
      :src="mediaUrl"
      @error="onVideoLoadError"
    />
    <div
      v-else
      class="flex items-center gap-1 px-5 py-4 text-center rounded-lg bg-n-alpha-1"
    >
      <Icon icon="i-lucide-circle-off" class="text-n-slate-11" />
      <p class="mb-0 text-n-slate-11">
        {{ $t('COMPONENTS.FILE_BUBBLE.INSTAGRAM_STORY_UNAVAILABLE') }}
      </p>
    </div>
  </BaseBubble>
</template>
