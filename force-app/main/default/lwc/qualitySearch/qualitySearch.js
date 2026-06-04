/**
 * Quality Search LWC.
 *
 * Imperative Apex call (not @wire) because the controller writes an audit
 * record on every invocation — the response is NOT cacheable.
 *
 * The Apex method takes FLAT String parameters, not an inner-class wrapper.
 * The LWC → Aura → Apex boundary deserialises inner-class arguments
 * unreliably: every field arrives as `null` regardless of what the JSON
 * payload contains. Flat parameters work.
 *
 * Client-side gate (`searchDisabled`) is a UX hint only. The 2-of-3 rule
 * is re-validated server-side in {@link QualitySearchController.search}.
 */
import { LightningElement } from 'lwc';
import search from '@salesforce/apex/QualitySearchController.search';

export default class QualitySearch extends LightningElement {
    email = '';
    phone = '';
    birthdate = '';
    lastName = '';
    firstName = '';
    city = '';
    matches = [];
    tooManyResults = false;
    isLoading = false;
    errorMessage = '';
    hasSearched = false;

    get qualitativeCount() {
        return [this.email, this.phone, this.birthdate].filter((v) => v && v.trim()).length;
    }

    get searchDisabled() {
        return this.isLoading || this.qualitativeCount < 2;
    }

    get gateHint() {
        const remaining = Math.max(0, 2 - this.qualitativeCount);
        if (remaining === 0) {
            return 'Ready to search.';
        }
        return `Provide ${remaining} more qualitative identifier${remaining === 1 ? '' : 's'} (Email, Phone, or Birthdate) to enable search.`;
    }

    get showNoResults() {
        return (
            this.hasSearched &&
            !this.tooManyResults &&
            this.matches.length === 0 &&
            !this.errorMessage
        );
    }

    get decoratedMatches() {
        return this.matches.map((m) => ({
            ...m,
            isPersonAccount: m.recordType === 'PersonAccount',
            typeLabel: m.recordType === 'PersonAccount' ? 'Person Account' : 'Business Contact',
            badgeClass:
                m.recordType === 'PersonAccount'
                    ? 'slds-badge slds-theme_success'
                    : 'slds-badge slds-theme_info'
        }));
    }

    handleChange(event) {
        this[event.target.dataset.field] = event.target.value;
    }

    async handleSearch() {
        this.isLoading = true;
        this.errorMessage = '';
        this.matches = [];
        this.tooManyResults = false;
        try {
            const result = await search({
                email: this.email,
                phone: this.phone,
                birthdate: this.birthdate,
                lastName: this.lastName,
                firstName: this.firstName,
                city: this.city
            });
            this.tooManyResults = result.tooManyResults;
            this.matches = result.matches ?? [];
        } catch (e) {
            this.errorMessage = e?.body?.message ?? 'Search failed.';
        } finally {
            this.isLoading = false;
            this.hasSearched = true;
        }
    }

    handleReset() {
        this.email = '';
        this.phone = '';
        this.birthdate = '';
        this.lastName = '';
        this.firstName = '';
        this.city = '';
        this.matches = [];
        this.tooManyResults = false;
        this.errorMessage = '';
        this.hasSearched = false;
    }
}
