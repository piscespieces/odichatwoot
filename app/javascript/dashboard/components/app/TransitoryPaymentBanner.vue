<script>
import { useAccount } from 'dashboard/composables/useAccount';
import Banner from 'dashboard/components/ui/Banner.vue';

export default {
  components: { Banner },
  setup() {
    const { accountId } = useAccount();
    return { accountId };
  },
  computed: {
    shouldShowBanner() {
      // -----------------------------------------------------------
      // ADD THE ACCOUNT IDs THAT SHOULD SEE THE BANNER HERE
      // -----------------------------------------------------------
      const overdueAccountIds = [6]; // Example: [1, 5]
      // -----------------------------------------------------------

      return overdueAccountIds.includes(Number(this.accountId));
    },
    bannerMessage() {
      const messages = {
        en: 'Payment Pending: Your service will be stopped soon if payment is not received. Please contact support to resolve this.',
        es: 'Pago Pendiente: Su servicio será suspendido pronto si no recibimos el pago. Por favor, póngase en contacto con soporte para resolverlo.',
      };
      const locale = this.$root.$i18n.locale || 'en';
      return messages[locale] || messages.en;
    },
  },
};
</script>

<template>
  <Banner
    v-if="shouldShowBanner"
    color-scheme="alert"
    :banner-message="bannerMessage"
  />
</template>
