import { LightningElement, api } from 'lwc';
import COMPANY_LOGO from '@salesforce/resourceUrl/Company_logo_blue';
import isGuest from '@salesforce/user/isGuest';
import demoLogin from '@salesforce/apex/LightningLoginFormController.demoLogin';
import isDemoLoginAvailable from '@salesforce/apex/LightningLoginFormController.isDemoLoginAvailable';

function parseLinks(raw) {
    if (!raw) return [];
    return raw
        .split(',')
        .map((chunk, i) => {
            const [label, url] = chunk.split('|').map((s) => (s || '').trim());
            if (!label) return null;
            return { key: `${i}-${label}`, label, url: url || '#' };
        })
        .filter(Boolean);
}

export default class PortalThemeLayout extends LightningElement {
    @api brandName = 'Northwind Insurance';
    @api navLinks = 'Dashboard|/, Policies|/, Claims|/, Support|/';
    @api footerNote = 'Cover explained in plain language, with an assistant that answers only from your policy documents.';
    @api hideAuthAction = false;

    menuOpen = false;
    headerAuthAction = null;
    headerClickUrl = null;

    // Static resource, resolved same-origin.
    get logoUrl() {
        return COMPANY_LOGO;
    }

    get showAuthAction() {
        return !this.hideAuthAction;
    }

    /* ---- demo account login (guest, login page only) ---- */

    demoAvailable = false;
    demoBusy = false;

    connectedCallback() {
        isDemoLoginAvailable()
            .then((available) => {
                this.demoAvailable = available === true;
            })
            .catch(() => {
                this.demoAvailable = false;
            });
    }

    /** Login page only — the button is meaningless anywhere else on the site. */
    get isLoginPage() {
        return window.location.pathname.toLowerCase().indexOf('login') !== -1;
    }

    get showDemoLogin() {
        return isGuest && this.demoAvailable && this.isLoginPage;
    }

    get demoLabel() {
        return this.demoBusy ? 'Signing in…' : 'Dummy Account Login';
    }

    async handleDemoLogin() {
        this.demoBusy = true;
        try {
            const url = await demoLogin({ startUrl: '/northwindinsurance/' });
            if (url) {
                window.location.href = url;
                return;                       // navigating away; stay disabled
            }
        } catch (e) {
            // fall through to reset the button
        }
        this.demoBusy = false;
    }

    get isGuestUser() {
        return isGuest;
    }

    get isKnownUser() {
        return !isGuest;
    }

    get links() {
        return parseLinks(this.navLinks);
    }

    get navClass() {
        return this.menuOpen ? 'site-nav site-nav--open' : 'site-nav';
    }

    get menuExpanded() {
        return this.menuOpen ? 'true' : 'false';
    }

    get year() {
        return new Date().getFullYear();
    }

    get loginUrl() {
        return '/northwindinsurance/login';
    }

    get homeUrl() {
        return (isGuest ? '/northwindinsurance/login' : '/');
    }

    get footerColumns() {
        return [
            {
                key: 'cover',
                title: 'Cover',
                items: [
                    { key: 'auto', label: 'Auto insurance', url: '/' },
                    { key: 'home', label: 'Home insurance', url: '/' },
                    { key: 'life', label: 'Life insurance', url: '/' },
                    { key: 'travel', label: 'Travel insurance', url: '/' }
                ]
            },
            {
                key: 'support',
                title: 'Support',
                items: [
                    { key: 'claims', label: 'Make a claim', url: '/' },
                    { key: 'help', label: 'Help centre', url: '/' },
                    { key: 'contact', label: 'Contact us', url: '/' }
                ]
            },
            {
                key: 'company',
                title: 'Company',
                items: [
                    { key: 'about', label: 'About Northwind', url: '/' },
                    { key: 'careers', label: 'Careers', url: '/' },
                    { key: 'security', label: 'Security', url: '/' }
                ]
            }
        ];
    }

    toggleMenu() {
        this.menuOpen = !this.menuOpen;
    }

    handleLogout() {
        window.location.href = '/northwindinsurance/secur/logout.jsp';
    }
}
