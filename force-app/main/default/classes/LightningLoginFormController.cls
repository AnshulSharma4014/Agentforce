global class LightningLoginFormController {

    public LightningLoginFormController() {
        
    }

    @AuraEnabled
    public static String login(String username, String password, String startUrl) {
        try{
            ApexPages.PageReference lgn = Site.login(username, password, startUrl);
            aura.redirect(lgn);
            return null;
        }
        catch (Exception ex) {
            return ex.getMessage();            
        }
    }
    
    @AuraEnabled
    public static Boolean getIsUsernamePasswordEnabled() {
        Auth.AuthConfiguration authConfig = getAuthConfig();
        return authConfig.getUsernamePasswordEnabled();
    }

    @AuraEnabled
    public static Boolean getIsSelfRegistrationEnabled() {
        Auth.AuthConfiguration authConfig = getAuthConfig();
        return authConfig.getSelfRegistrationEnabled();
    }

    @AuraEnabled
    public static String getSelfRegistrationUrl() {
        Auth.AuthConfiguration authConfig = getAuthConfig();
        if (authConfig.getSelfRegistrationEnabled()) {
            return authConfig.getSelfRegistrationUrl();
        }
        return null;
    }

    @AuraEnabled
    public static String getForgotPasswordUrl() {
        Auth.AuthConfiguration authConfig = getAuthConfig();
        return authConfig.getForgotPasswordUrl();
    }
    
    @TestVisible
    private static Auth.AuthConfiguration getAuthConfig(){
        Id networkId = Network.getNetworkId();
        Auth.AuthConfiguration authConfig = new Auth.AuthConfiguration(networkId,'');
        return authConfig;
    }

    @AuraEnabled
    global static String setExperienceId(String expId) {
        // Return null if there is no error, else it will return the error message
        try {
            if (expId != null) {
                Site.setExperienceId(expId);
            }
            return null;
        } catch (Exception ex) {
            return ex.getMessage();
        }
    }

    /**
     * Signs the visitor in as the shared demo account behind the "Dummy Account Login"
     * button, so recruiters can see the portal without registering.
     *
     * Credentials come from the PROTECTED custom setting Demo_Login_Config__c, never
     * from the caller and never from source: the repository is public, and a password
     * committed to it stays in git history long after the demo account is retired.
     * Site.login runs here, so the password is never sent to the browser either.
     *
     * Returns the redirect URL on success, or null when the account is not configured
     * or sign-in fails. Deliberately does not say which — a precise error would turn a
     * public button into a credential probe against the org.
     */
    @AuraEnabled
    global static String demoLogin(String startUrl) {
        // getInstance walks user -> profile -> org, so the value is found wherever it is
        // set. Guests have no profile-level record, so the ORG-level value is the one
        // that actually matters for this button.
        Demo_Login_Config__c cfg = Demo_Login_Config__c.getInstance();
        if (cfg == null
                || String.isBlank(cfg.Username__c)
                || String.isBlank(cfg.Password__c)) {
            return null;
        }
        try {
            ApexPages.PageReference lgn = Site.login(
                cfg.Username__c,
                cfg.Password__c,
                String.isBlank(startUrl) ? '/' : startUrl);
            return lgn == null ? null : lgn.getUrl();
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Demo login failed: ' + ex.getMessage());
            return null;
        }
    }

    /** True when a demo account is configured, so the button can hide itself. */
    @AuraEnabled(cacheable=true)
    global static Boolean isDemoLoginAvailable() {
        // getInstance walks user -> profile -> org, so the value is found wherever it is
        // set. Guests have no profile-level record, so the ORG-level value is the one
        // that actually matters for this button.
        Demo_Login_Config__c cfg = Demo_Login_Config__c.getInstance();
        return cfg != null
            && String.isNotBlank(cfg.Username__c)
            && String.isNotBlank(cfg.Password__c);
    }
}