# See bottom of file for license and copyright information
use strict;
use warnings;

package MailTemplatesContribTests;

use FoswikiFnTestCase;
our @ISA = qw( FoswikiFnTestCase );

use strict;
use warnings;

use Foswiki();
use Error qw ( :try );
use Foswiki::Contrib::MailTemplatesContrib();

use Test::MockModule;

my $users;
my @attachments;

my $mocks; # mocks will be stored in a package variable, so we can unmock them reliably when the test finished

sub new {
    my ($class, @args) = @_;
    my $this = shift()->SUPER::new('MailTemplatesContribTests', @args);
    return $this;
}

sub tear_down {
    my $this = shift;

    foreach my $module (keys %$mocks) {
        $mocks->{$module}->unmock_all();
    }

    $this->SUPER::tear_down();
}

# Will prepare mocks to simulate a call via tools/mailtemplatesend or browser
sub _mock {
    my ($settings) = @_;
    $settings ||= {};

    $mocks = {};
    foreach my $module (qw( Foswiki Foswiki::Contrib::MailTemplatesContrib Foswiki::Func Foswiki::I18N Foswiki::Plugins::DefaultPreferencesPlugin )) {
        $mocks->{$module} = Test::MockModule->new($module);
    }

    # create a new request to mock params
    my $cliParams = $settings->{parameters} || { template => 'Dummy', action => 'mailtemplatesend' };
    my $query = Unit::Request->new( $cliParams );
    $mocks->{'Foswiki::Func'}->mock('getRequestObject', $query);

    # make getContext purport we are called from cli
    unless($settings->{noCli}) {
        $mocks->{Foswiki}->mock('inContext', sub {
            return 1 if $_[1] eq 'command_line';
            return &{$mocks->{Foswiki}->original('inContext')}(@_);
        });
    };

    $mocks->{'Foswiki::Func'}->mock('getPreferencesValue', sub {
        return $settings->{Preferences}{$_[0]} if exists $settings->{Preferences}{$_[0]};
        return $settings->{SitePreferences}{$_[0]};
    });

    $mocks->{'Foswiki::Plugins::DefaultPreferencesPlugin'}->mock('getSitePreferencesValue', sub {
        return $settings->{SitePreferences}{$_[0]};
    });

    $mocks->{'Foswiki::Contrib::MailTemplatesContrib'}->mock('_sendGeneratedMails', undef);

    # purport our browserlanguage to be en
    $mocks->{'Foswiki::I18N'}->mock('language', 'en');

    my ($calledRef, $languageRef) = ($settings->{called} || my $dummyCalled, $settings->{language} || my $dummyLang);
    $mocks->{'Foswiki::Contrib::MailTemplatesContrib'}->mock('_generateMails', sub {
        my ($template, $options, $setPreferences) = @_;
        $$calledRef = 1;
        $$languageRef = $setPreferences->{LANGUAGE};
    });
}

# When used from cli...
# ... the language defaults to undef (en) when not specified
sub test_languageDefaultsToEnTests {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
    });

    Foswiki::Contrib::MailTemplatesContrib::_sendCli();

    $this->assert($called, 'Mails where not gererated');
    $this->assert(!defined $language, "LANGUAGE exists: " . ($language || 'undef'));
}

# When used from cli...
# ... a LANGUAGE set on Web/SitePreferences will be used
sub test_useLANGUAGEfromSitePreferences {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        Preferences => {
            LANGUAGE => 'tlh',
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::_sendCli();

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'tlh', "LANGUAGE preference was not used: " .($language || 'undef'));
}

# When used from cli...
# ... a MAIL_LANGUAGE set on SitePreferences will be used
# ... a MAIL_LANGUAGE overrides LANGUAGE from SitePreferences
sub test_useMAIL_LANGUAGEfromSitePreferences {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        SitePreferences => {
            LANGUAGE => 'tlh',
            MAIL_LANGUAGE => 'fr',
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::_sendCli();

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'fr', "MAIL_LANGUAGE preference was not used: " .($language || 'undef'));
}

# When used from cli...
# ... a BACKEND_MAIL_LANGUAGE set on SitePreferences will be used
# ... a BACKEND_MAIL_LANGUAGE overrides MAIL_LANGUAGE from SitePreferences
# ... a BACKEND_MAIL_LANGUAGE overrides LANGUAGE from SitePreferences
sub test_useBACKEND_MAIL_LANGUAGEfromSitePreferences {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        SitePreferences => {
            LANGUAGE => 'tlh',
            MAIL_LANGUAGE => 'fr',
            BACKEND_MAIL_LANGUAGE => 'it'
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::_sendCli();

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'it', "MAIL_LANGUAGE preference was not used: " .($language || 'undef'));
}

# When used from cli...
# ... a LANGUAGE set on the cli will be used
# ... a LANGUAGE overrides BACKEND_MAIL_LANGUAGE from SitePreferences
# ... a LANGUAGE overrides MAIL_LANGUAGE from SitePreferences
# ... a LANGUAGE overrides LANGUAGE from SitePreferences
sub test_useLANGUAGEfromCli {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        parameters => {
            template => 'Dummy',
            LANGUAGE => 'zh-cn',
        },
        SitePreferences => {
            LANGUAGE => 'tlh',
            MAIL_LANGUAGE => 'fr',
            BACKEND_MAIL_LANGUAGE => 'it'
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::_sendCli();

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'zh-cn', "LANGUAGE parameter was not used: " .($language || 'undef'));
}

# When used from browser...
# ... MAIL_LANGUAGE will be used
# ... BACKEND_MAIL_LANGUAGE does NOT override anything
sub test_useMAIL_LANGUAGEfromBrowser {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        noCli => 1,
        SitePreferences => {
            MAIL_LANGUAGE => 'fr',
            BACKEND_MAIL_LANGUAGE => 'it'
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::sendMail('Dummy', {}, {});

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'fr', "MAIL_LANGUAGE did not apply: " .($language || 'undef'));
}

# When used from browser...
# ... language defaults to en
# ... BACKEND_MAIL_LANGUAGE does NOT override anything
sub test_useLanguagefromBrowser {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        noCli => 1,
        SitePreferences => {
            BACKEND_MAIL_LANGUAGE => 'it'
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::sendMail('Dummy', {}, {});

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'en', "Browser language did not apply: " .($language || 'undef'));
}

# When used from browser...
# ... LANGUAGE (setting) will be used
# ... LANGUAGE will override MAIL_LANGUAGE
# ... BACKEND_MAIL_LANGUAGE does NOT override anything
sub test_useLANGUAGEfromBrowser {
    my ( $this ) = @_;

    my ($called, $language);
    _mock({
        called => \$called,
        language => \$language,
        noCli => 1,
        SitePreferences => {
            MAIL_LANGUAGE => 'fr',
            BACKEND_MAIL_LANGUAGE => 'it'
        }
    });

    Foswiki::Contrib::MailTemplatesContrib::sendMail('Dummy', {}, { LANGUAGE => 'tlh' });

    $this->assert($called, 'Mails where not gererated');
    $this->assert($language eq 'tlh', "LANGUAGE did not apply: " .($language || 'undef'));
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Author: Modell Aachen GmbH

Copyright (C) 2008-2011 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
