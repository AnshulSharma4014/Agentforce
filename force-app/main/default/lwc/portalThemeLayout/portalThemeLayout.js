import { LightningElement, api } from 'lwc';
import COMPANY_LOGO from '@salesforce/resourceUrl/Company_logo_blue';
import isGuest from '@salesforce/user/isGuest';

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

    // Static resource, resolved same-origin.
    get logoUrl() {
        return COMPANY_LOGO;
    }

    get showAuthAction() {
        return !this.hideAuthAction;
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

    connectedCallback() {
        if(window.location.href?.toLowerCase()?.includes('login')) {
            this.headerAuthAction = 'Sign up';
        } else if(window.location.href?.toLowerCase()?.includes('selfregister')) {
            this.headerAuthAction = 'Log in';
        } else {
            this.headerAuthAction = 'Logout';
        }
    }
}
