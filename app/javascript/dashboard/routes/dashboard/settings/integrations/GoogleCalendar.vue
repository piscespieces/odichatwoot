<script setup>
import { ref, onMounted, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import {
  useFunctionGetter,
  useMapGetter,
  useStore,
} from 'dashboard/composables/store';

import Integration from './Integration.vue';
import Spinner from 'shared/components/Spinner.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import googleCalendarClient from 'dashboard/api/google_calendar_auth.js';

const store = useStore();
const { t } = useI18n();

const integration = useFunctionGetter(
  'integrations/getIntegration',
  'google_calendar'
);
const uiFlags = useMapGetter('integrations/getUIFlags');
const integrationData = computed(() => integration.value || {});
const integrationAction = computed(() => {
  if (integrationData.value.enabled) {
    return 'disconnect';
  }
  return '';
});

const integrationLoaded = ref(false);
const isConnecting = ref(false);

const initializeIntegration = async () => {
  await store.dispatch('integrations/get', 'google_calendar');
  integrationLoaded.value = true;
};

const handleConnectClick = async () => {
  try {
    isConnecting.value = true;
    const response = await googleCalendarClient.generateAuthorization();
    const {
      data: { url },
    } = response;
    window.location.href = url;
  } catch (error) {
    useAlert(t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.ERROR'));
  } finally {
    isConnecting.value = false;
  }
};

onMounted(() => {
  initializeIntegration();
});
</script>

<template>
  <div class="flex-grow flex-shrink overflow-auto max-w-6xl mx-auto p-4">
    <div
      v-if="integrationLoaded && !uiFlags.isFetching"
      class="flex flex-col gap-6"
    >
      <Integration
        v-if="integrationData.id"
        :integration-id="integrationData.id"
        :integration-logo="integrationData.logo"
        :integration-name="integrationData.name"
        :integration-description="integrationData.description"
        :integration-enabled="integrationData.enabled"
        :integration-action="integrationAction"
        :action-button-text="
          $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.DISCONNECT')
        "
        :delete-confirmation-text="{
          title: $t(
            'INTEGRATION_SETTINGS.GOOGLE_CALENDAR.DELETE_CONFIRMATION.TITLE'
          ),
          message: $t(
            'INTEGRATION_SETTINGS.GOOGLE_CALENDAR.DELETE_CONFIRMATION.MESSAGE'
          ),
        }"
      >
        <template #action>
          <Button
            blue
            solid
            :label="$t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.CTA')"
            :is-loading="isConnecting"
            @click="handleConnectClick"
          />
        </template>
      </Integration>

      <section
        class="outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow p-6 flex flex-col gap-4"
      >
        <div>
          <h4 class="text-lg font-semibold text-n-slate-12">
            {{ $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.HELP.TITLE') }}
          </h4>
          <p class="text-sm text-n-slate-11 leading-6 mt-1">
            {{ $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.HELP.BODY') }}
          </p>
        </div>
        <ol class="list-decimal pl-4 space-y-2 text-sm text-n-slate-12">
          <li>
            {{ $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.HELP.STEPS.ONE') }}
          </li>
          <li>
            {{ $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.HELP.STEPS.TWO') }}
          </li>
          <li>
            {{ $t('INTEGRATION_SETTINGS.GOOGLE_CALENDAR.HELP.STEPS.THREE') }}
          </li>
        </ol>
      </section>
    </div>
    <div v-else class="flex items-center justify-center flex-1 min-h-[280px]">
      <Spinner size="" color-scheme="primary" />
    </div>
  </div>
</template>
