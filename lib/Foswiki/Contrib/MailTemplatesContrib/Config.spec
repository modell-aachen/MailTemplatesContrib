# ---+ Extensions
# ---++ MailTemplatesContribPlugin
# **PERL H**
# This setting is required to enable sending mails from cli via tools/mailtemplate_send
$Foswiki::cfg{SwitchBoard}{mailtemplatesend} = ['Foswiki::Contrib::MailTemplatesContrib', '_sendCli', { }];

# **BOOLEAN**
# Use Grinder to send mails (have it configured!)
$Foswiki::cfg{Extension}{MailTemplatesContrib}{UseGrinder} = 0;

