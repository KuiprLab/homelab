{
  orgId = "kuiprde";
  orgName = "kuipr.de";
  orgSubnet = "100.90.128.0/20";
  orgUtilitySubnet = "100.96.128.0/20";
  apiUrl = "http://127.0.0.1:3000/api/v1";
  dashboardDomain = "pangolin.ext.kuipr.de";
  baseDomain = "kuipr.de";
  oidcIssuer = "https://auth.ext.kuipr.de";
  tolerance = 5 * 60;
  # niceId is also the newt --id; secretEnv names the variable in secrets/eclair/pangolin-apply.env.
  sites = {
    eclair = {
      niceId = "eclair";
      secretEnv = "NEWT_SECRET_ECLAIR";
    };
    sorbet = {
      niceId = "sorbet";
      secretEnv = "NEWT_SECRET_SORBET";
    };
  };
}
