/**
 * Quality Search LWC — dynamic, config-driven form.
 *
 * The form layout (which inputs exist, their labels, types, and gate role)
 * comes from `QualitySearchController.getFormConfig(configName)`. The LWC
 * renders the inputs via `<template for:each>` and tracks their values in
 * a single `inputValues` object keyed by input developerName.
 *
 * The Search button is enabled when the count of filled qualitative inputs
 * meets or exceeds the config's threshold. The same rule is re-validated
 * server-side — disabling the button is only a UX convenience.
 *
 * Imperative call (not @wire) to `search` because the Apex method writes
 * an audit row on every invocation — the response must not be cached.
 *
 * Apex parameters are flat (String configName, Map<String,String> inputs).
 * Salesforce's LWC → Aura → Apex JSON bridge deserialises strongly-typed
 * Apex inner classes unreliably for input parameters; generic Maps work.
 */
import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getFormConfig from '@salesforce/apex/QualitySearchController.getFormConfig';
import search from '@salesforce/apex/QualitySearchController.search';

export default class QualitySearch extends LightningElement {
    /** App Builder design attribute. Default: 'Default' Quality_Search_Config__mdt. */
    @api configName = 'Default';

    /** Raw user values keyed by InputDef.developerName.
     *  Spread-replaced on each change to keep reactivity simple. */
    @track inputValues = {};

    formConfig;
    formConfigError;
    wiredConfig; // cached @wire result for refreshApex
    matches = [];
    tooManyResults = false;
    isLoading = false;
    errorMessage = '';
    hasSearched = false;

    @wire(getFormConfig, { configName: '$configName' })
    wiredGetFormConfig(result) {
        this.wiredConfig = result;
        if (result.data) {
            this.formConfig = result.data;
            this.formConfigError = undefined;
        } else if (result.error) {
            this.formConfig = undefined;
            this.formConfigError =
                result.error?.body?.message ?? 'Failed to load Quality Search configuration.';
        }
    }

    // ─── Derived state ────────────────────────────────────────────────────

    get qualitativeInputs() {
        return (this.formConfig?.inputs ?? []).filter((i) => i.role === 'Qualitative');
    }

    get filterInputs() {
        return (this.formConfig?.inputs ?? []).filter((i) => i.role === 'Filter');
    }

    get qualitativeCount() {
        return this.qualitativeInputs.filter((i) => {
            const v = this.inputValues[i.developerName];
            return v && String(v).trim().length > 0;
        }).length;
    }

    get qualitativeThreshold() {
        return this.formConfig?.qualitativeThreshold ?? 2;
    }

    get hasFilters() {
        return this.filterInputs.length > 0;
    }

    get searchDisabled() {
        return (
            !this.formConfig ||
            this.isLoading ||
            this.qualitativeCount < this.qualitativeThreshold
        );
    }

    get gateHint() {
        if (!this.formConfig) return '';
        const remaining = Math.max(0, this.qualitativeThreshold - this.qualitativeCount);
        if (remaining === 0) return 'Ready to search.';
        return `Provide ${remaining} more qualitative identifier${remaining === 1 ? '' : 's'} to enable search.`;
    }

    get showNoResults() {
        return (
            this.hasSearched &&
            !this.tooManyResults &&
            this.matches.length === 0 &&
            !this.errorMessage
        );
    }

    /** Decorates the raw Apex DTOs for rendering. */
    get decoratedMatches() {
        return this.matches.map((m) => ({
            ...m,
            badgeClass: 'slds-badge slds-theme_info',
            fields: (m.fields ?? []).map((f) => ({
                ...f,
                isEmail: f.fieldType === 'email',
                isPhone: f.fieldType === 'phone',
                isDate: f.fieldType === 'date',
                isText: !['email', 'phone', 'date'].includes(f.fieldType)
            }))
        }));
    }

    /** Decorates the input list with bound values for rendering. */
    get decoratedQualitativeInputs() {
        return this.qualitativeInputs.map((i) => ({
            ...i,
            value: this.inputValues[i.developerName] ?? ''
        }));
    }
    get decoratedFilterInputs() {
        return this.filterInputs.map((i) => ({
            ...i,
            value: this.inputValues[i.developerName] ?? ''
        }));
    }

    // ─── Handlers ─────────────────────────────────────────────────────────

    handleChange(event) {
        const field = event.target.dataset.field;
        this.inputValues = { ...this.inputValues, [field]: event.target.value };
    }

    async handleSearch() {
        this.isLoading = true;
        this.errorMessage = '';
        this.matches = [];
        this.tooManyResults = false;
        try {
            // Send a flat copy — the @track proxy isn't directly serialisable.
            const payload = { ...this.inputValues };
            const result = await search({ configName: this.configName, inputs: payload });
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
        this.inputValues = {};
        this.matches = [];
        this.tooManyResults = false;
        this.errorMessage = '';
        this.hasSearched = false;
    }

    async handleReloadConfig() {
        // Useful when an admin updates CMDT and wants the form to pick up
        // the change without a full page refresh.
        await refreshApex(this.wiredConfig);
    }
}
