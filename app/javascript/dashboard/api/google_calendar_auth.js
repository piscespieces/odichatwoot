/* global axios */

import ApiClient from './ApiClient';

class GoogleCalendarOAuthClient extends ApiClient {
  constructor() {
    super('google_calendar', { accountScoped: true });
  }

  generateAuthorization() {
    return axios.post(`${this.url}/authorization`);
  }
}

export default new GoogleCalendarOAuthClient();
