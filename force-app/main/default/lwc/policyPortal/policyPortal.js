import { LightningElement, wire, track } from 'lwc';
import COMPANY_LOGO from '@salesforce/resourceUrl/Company_logo_blue';
import { refreshApex } from '@salesforce/apex';
import getPortalData from '@salesforce/apex/PolicyPortalController.getPortalData';
import getApplyOptions from '@salesforce/apex/PolicyPortalController.getApplyOptions';
import getPolicyDetail from '@salesforce/apex/PolicyPortalController.getPolicyDetail';
import createPolicy from '@salesforce/apex/PolicyPortalController.createPolicy';

const VIEW_ALL = 'all';
const VIEW_EXPIRING = 'expiring';
const VIEW_APPLY = 'apply';
const VIEW_DETAIL = 'detail';

// A policy counts as "expiring" inside this window.
const EXPIRING_WINDOW_DAYS = 30;

const OPEN_STATUSES = ['active', 'pending', 'suspended'];

/** Policy_Type__c values vary, so match on keywords rather than exact strings. */
const TYPE_TILES = [
    { match: ['auto', 'motor', 'vehicle', 'car'], tile: 'auto' },
    { match: ['home', 'house', 'property', 'asset'], tile: 'home' },
    { match: ['life'], tile: 'life' },
    { match: ['health', 'medical'], tile: 'health' },
    { match: ['travel', 'liability'], tile: 'travel' }
];

const EMPTY_FORM = {
    policyType: '',
    tenure: '',
    sumInsured: '',
    paymentFrequency: '',
    premiumAmount: ''
};

/** Month arithmetic that never rolls into the next month (31 Jan + 1 => 28/29 Feb). */
function addMonths(date, months) {
    const d = new Date(date.getTime());
    const day = d.getDate();
    d.setDate(1);
    d.setMonth(d.getMonth() + months);
    d.setDate(Math.min(day, new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()));
    return d;
}

export default class PolicyPortal extends LightningElement {
    @track policies = [];
    greetingName = 'there';
    totalCount = 0;

    isLoading = true;
    hasError = false;
    errorMessage = '';

    activeView = VIEW_ALL;
    sortField = 'expirationDate';
    sortAsc = true;
    navOpen = false;

    // apply form
    @track form = { ...EMPTY_FORM };
    options;
    isSaving = false;
    formError = '';

    // detail
    @track detail = null;
    detailLoading = false;
    detailMissing = false;

    skeletons = [1, 2, 3, 4, 5, 6];

    sortOptions = [
        { value: 'expirationDate', label: 'Sort by expiration' },
        { value: 'sumInsured', label: 'Sort by sum insured' },
        { value: 'policyType', label: 'Sort by policy type' },
        { value: 'status', label: 'Sort by status' }
    ];

    wiredResult;

    @wire(getPortalData, { scope: 'ALL' })
    handleData(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.greetingName = data.greetingName || 'there';
            this.totalCount = data.totalCount || 0;
            this.policies = (data.policies || []).map((p) => this.decorate(p));
            this.hasError = false;
            this.isLoading = false;
        } else if (error) {
            this.hasError = true;
            this.errorMessage = this.readError(error);
            this.isLoading = false;
        }
    }

    @wire(getApplyOptions)
    handleOptions({ data }) {
        if (data) this.options = data;
    }

    /* ---------------- derived data ---------------- */

    get rows() {
        const filtered = this.policies.filter((p) => this.matchesView(p));
        const dir = this.sortAsc ? 1 : -1;
        const field = this.sortField;

        return [...filtered]
            .sort((a, b) => {
                // Closed cover always sinks. Otherwise "soonest first" puts policies that
                // expired months ago at the top of a dashboard about active cover.
                if (a.isClosed !== b.isClosed) return a.isClosed ? 1 : -1;

                const av = a.sortKeys[field];
                const bv = b.sortKeys[field];
                if (av === bv) return a.sortKeys.expirationDate - b.sortKeys.expirationDate;
                if (av === null || av === undefined) return 1;
                if (bv === null || bv === undefined) return -1;
                return av > bv ? dir : -dir;
            })
            .map((p, i) => ({ ...p, index: i + 1 }));
    }

    matchesView(p) {
        if (this.activeView === VIEW_EXPIRING) return p.isExpiring;
        return true;
    }

    get expiringCount() {
        return this.policies.filter((p) => p.isExpiring).length;
    }

    get navItems() {
        const items = [
            { id: VIEW_ALL, label: 'All policies', count: this.policies.length },
            { id: VIEW_EXPIRING, label: 'Expiring policies', count: this.expiringCount },
            { id: VIEW_APPLY, label: 'Apply for a policy', count: 0 }
        ];
        return items.map((it) => {
            const active = it.id === this.activeView;
            return {
                ...it,
                cssClass: active ? 'nav__item nav__item--active' : 'nav__item',
                ariaCurrent: active ? 'page' : 'false',
                showCount: it.id !== VIEW_APPLY && it.count > 0
            };
        });
    }

    // Static resource, resolved same-origin so it is not subject to the CSP
    // restrictions that block cross-domain image hosts.
    get logoUrl() {
        return COMPANY_LOGO;
    }

    get sidebarClass() {
        return this.navOpen ? 'sidebar sidebar--open' : 'sidebar';
    }

    get initial() {
        return (this.greetingName || '?').trim().charAt(0).toUpperCase();
    }

    get isApplyView() {
        return this.activeView === VIEW_APPLY;
    }

    get isDetailView() {
        return this.activeView === VIEW_DETAIL;
    }

    get isListView() {
        return this.activeView === VIEW_ALL || this.activeView === VIEW_EXPIRING;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showTools() {
        return this.isListView;
    }

    get activeTitle() {
        if (this.activeView === VIEW_EXPIRING) return 'Expiring policies';
        if (this.activeView === VIEW_APPLY) return 'Apply for a policy';
        if (this.activeView === VIEW_DETAIL) return 'Policy details';
        return 'Dashboard';
    }

    get activeSubtitle() {
        if (this.activeView === VIEW_EXPIRING) {
            return `Policies expiring within ${EXPIRING_WINDOW_DAYS} days, soonest first.`;
        }
        if (this.activeView === VIEW_APPLY) {
            return 'Choose your cover and we will work out the dates and deductible.';
        }
        if (this.activeView === VIEW_DETAIL) {
            return 'Everything we hold for this policy.';
        }
        return 'Overview of your policies, sorted by expiration date.';
    }

    get emptyTitle() {
        return this.activeView === VIEW_EXPIRING ? 'Nothing expiring soon' : 'No policies yet';
    }

    get emptyBody() {
        if (this.activeView === VIEW_EXPIRING) {
            return `None of your policies expire in the next ${EXPIRING_WINDOW_DAYS} days.`;
        }
        return "We couldn't find any policies on your account. If that looks wrong, our assistant can help.";
    }

    get sortDirectionLabel() {
        return this.sortAsc ? 'Soonest first' : 'Latest first';
    }

    /* ---------------- apply form ---------------- */

    get policyTypeOptions() {
        return this.options ? this.options.policyTypes : [];
    }

    get tenureOptions() {
        return this.options ? this.options.tenures : [];
    }

    get frequencyOptions() {
        return this.options ? this.options.frequencies : [];
    }

    get applyBlocked() {
        return !!this.options && this.options.canApply === false;
    }

    get applyBlockedReason() {
        return this.options ? this.options.blockedReason : '';
    }

    get hasFormError() {
        return !!this.formError;
    }

    get canSubmit() {
        const f = this.form;
        return (
            !this.isSaving &&
            !this.applyBlocked &&
            f.policyType &&
            f.tenure &&
            f.paymentFrequency &&
            Number(f.sumInsured) > 0 &&
            Number(f.premiumAmount) > 0
        );
    }

    get submitDisabled() {
        return !this.canSubmit;
    }

    get submitLabel() {
        return this.isSaving ? 'Submitting…' : 'Submit application';
    }

    /**
     * Live preview of what the server will derive. The rules (tenure months, payment
     * interval, deductible rate) come from Apex via getApplyOptions, so there is one
     * definition — this cannot drift from what actually gets saved.
     */
    get preview() {
        const tenure = this.tenureOptions.find((t) => t.value === this.form.tenure);
        const freq = this.frequencyOptions.find((f) => f.value === this.form.paymentFrequency);
        const sum = Number(this.form.sumInsured);

        const start = new Date();
        const rows = [];

        rows.push({ key: 'eff', label: 'Effective date', value: this.dateLabel(start) });

        if (tenure) {
            const finish = addMonths(start, tenure.months);
            rows.push({ key: 'exp', label: 'Expiration date', value: this.dateLabel(finish) });

            if (freq) {
                const due = addMonths(start, freq.months);
                rows.push({
                    key: 'next',
                    label: 'Next payment due',
                    value: due > finish ? 'Paid up front' : this.dateLabel(due)
                });
            }
        } else {
            rows.push({ key: 'exp', label: 'Expiration date', value: 'Choose a tenure' });
        }

        if (freq && sum > 0) {
            rows.push({
                key: 'ded',
                label: 'Deductible',
                value: this.currency(sum * freq.rate)
            });
        } else {
            rows.push({ key: 'ded', label: 'Deductible', value: 'Choose frequency & sum insured' });
        }

        return rows;
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.target.value };
        this.formError = '';
    }

    async handleSubmit() {
        if (!this.canSubmit) return;
        this.isSaving = true;
        this.formError = '';
        try {
            const policyNumber = await createPolicy({
                policyType: this.form.policyType,
                tenure: this.form.tenure,
                sumInsured: Number(this.form.sumInsured),
                paymentFrequency: this.form.paymentFrequency,
                premiumAmount: Number(this.form.premiumAmount)
            });
            this.form = { ...EMPTY_FORM };
            await refreshApex(this.wiredResult);
            await this.openDetail(policyNumber);
        } catch (error) {
            this.formError = this.readError(error);
        } finally {
            this.isSaving = false;
        }
    }

    handleResetForm() {
        this.form = { ...EMPTY_FORM };
        this.formError = '';
    }

    /* ---------------- detail ---------------- */

    async openDetail(policyNumber) {
        this.activeView = VIEW_DETAIL;
        this.detailLoading = true;
        this.detailMissing = false;
        this.detail = null;
        try {
            const raw = await getPolicyDetail({ policyNumber });
            if (raw) {
                this.detail = this.decorateDetail(raw);
            } else {
                this.detailMissing = true;
            }
        } catch (error) {
            this.detailMissing = true;
            this.errorMessage = this.readError(error);
        } finally {
            this.detailLoading = false;
        }
    }

    handleRowOpen(event) {
        const number = event.currentTarget.dataset.number;
        if (number) this.openDetail(number);
    }

    handleRowKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleRowOpen(event);
        }
    }

    handleBack() {
        this.activeView = VIEW_ALL;
        this.detail = null;
    }

    decorateDetail(p) {
        const base = this.decorate(p);
        const days = this.numberOrNull(p.daysToExpiration);

        return {
            ...base,
            fields: [
                { key: 'type', label: 'Policy type', value: base.policyType },
                { key: 'status', label: 'Status', value: base.statusLabel },
                { key: 'sum', label: 'Sum insured', value: base.sumInsuredText },
                {
                    key: 'premium',
                    label: 'Premium amount',
                    value: this.currency(this.numberOrNull(p.premiumAmount))
                },
                {
                    key: 'ded',
                    label: 'Deductible',
                    value: this.currency(this.numberOrNull(p.deductible))
                },
                { key: 'freq', label: 'Payment frequency', value: p.paymentFrequency || '—' },
                {
                    key: 'eff',
                    label: 'Effective date',
                    value: this.dateLabel(this.toDate(p.effectiveDate))
                },
                { key: 'exp', label: 'Expiration date', value: base.expirationText },
                {
                    key: 'next',
                    label: 'Next payment due',
                    value: p.nextPaymentDueDate
                        ? this.dateLabel(this.toDate(p.nextPaymentDueDate))
                        : 'Paid up front'
                },
                {
                    key: 'days',
                    label: 'Days to expiration',
                    value: days === null ? '—' : days < 0 ? `${Math.abs(days)} days ago` : `${days} days`
                }
            ]
        };
    }

    /* ---------------- events ---------------- */

    handleNav(event) {
        this.activeView = event.currentTarget.dataset.id;
        this.navOpen = false;
        this.formError = '';
    }

    handleSortField(event) {
        this.sortField = event.target.value;
    }

    toggleSortDirection() {
        this.sortAsc = !this.sortAsc;
    }

    toggleNav() {
        this.navOpen = !this.navOpen;
    }

    handleExplore() {
        this.activeView = VIEW_APPLY;
    }

    handleLogout() {
        window.location.href = '/secur/logout.jsp';
    }

    reload() {
        this.isLoading = true;
        this.hasError = false;
        window.location.reload();
    }

    /* ---------------- helpers ---------------- */

    decorate(p) {
        const days = this.numberOrNull(p.daysToExpiration);
        const sum = this.numberOrNull(p.sumInsured);
        const status = (p.status || '').toString();
        const statusKey = status.toLowerCase();
        const expired = days !== null && days < 0;
        const isOpen = OPEN_STATUSES.includes(statusKey);
        const isExpiring = isOpen && days !== null && days >= 0 && days <= EXPIRING_WINDOW_DAYS;

        let pillModifier = 'neutral';
        let statusLabel = status || 'Unknown';
        if (isExpiring) {
            pillModifier = 'warn';
            statusLabel = 'Expiring Soon';
        } else if (expired || statusKey === 'expired') {
            pillModifier = 'muted';
            // A policy whose date has passed reads "Expired" even if the record still
            // says Active — showing "Active" next to a past date is actively misleading.
            statusLabel = 'Expired';
        } else if (statusKey === 'cancelled') {
            pillModifier = 'danger';
        } else if (statusKey === 'active') {
            pillModifier = 'ok';
        } else if (statusKey === 'pending' || statusKey === 'suspended') {
            pillModifier = 'info';
        }

        const expirationDate = this.toDate(p.expirationDate);
        const isClosed = !isOpen || (expired && statusKey !== 'pending');

        return {
            policyNumber: p.policyNumber,
            policyNumberText: p.policyNumber ? `#${p.policyNumber}` : '—',
            policyType: p.policyType || 'Policy',
            statusLabel,
            isExpiring,
            isClosed,
            rowClass: isClosed ? 'row row--closed' : 'row',
            cardClass: isClosed ? 'pcard row--closed' : 'pcard',
            tileClass: `tile tile--${this.tileFor(p.policyType)}`,
            pillClass: `pill pill--${pillModifier}`,
            sumInsuredText: this.currency(sum),
            expirationText: this.dateLabel(expirationDate),
            sortKeys: {
                expirationDate: expirationDate ? expirationDate.getTime() : Number.MAX_SAFE_INTEGER,
                sumInsured: sum === null ? -1 : sum,
                policyType: (p.policyType || '').toLowerCase(),
                status: statusKey
            }
        };
    }

    tileFor(type) {
        const t = (type || '').toLowerCase();
        const hit = TYPE_TILES.find((entry) => entry.match.some((m) => t.includes(m)));
        return hit ? hit.tile : 'default';
    }

    numberOrNull(v) {
        if (v === null || v === undefined || v === '') return null;
        const n = Number(v);
        return Number.isNaN(n) ? null : n;
    }

    toDate(value) {
        if (!value) return null;
        // Apex sends yyyy-MM-dd; parse as local to avoid a timezone-induced day shift.
        const parts = String(value).split('-');
        if (parts.length === 3) {
            return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
        }
        const d = new Date(value);
        return Number.isNaN(d.getTime()) ? null : d;
    }

    currency(n) {
        if (n === null || n === undefined) return '—';
        return new Intl.NumberFormat(undefined, {
            style: 'currency',
            currency: 'USD',
            maximumFractionDigits: 0
        }).format(n);
    }

    dateLabel(d) {
        if (!d) return '—';
        return new Intl.DateTimeFormat(undefined, {
            month: 'short',
            day: 'numeric',
            year: 'numeric'
        }).format(d);
    }

    readError(error) {
        if (!error) return 'Unknown error.';
        if (error.body && error.body.message) return error.body.message;
        if (Array.isArray(error.body) && error.body.length) return error.body[0].message;
        return error.message || 'Unknown error.';
    }
}
