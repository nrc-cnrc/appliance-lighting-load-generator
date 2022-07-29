#=================================================================================================================
#   This file is part of Appliance_Lighting_Generator. This is a set of scripts used to generate sub-hourly annual
#   occupancy, and appliance and lighting demand profiles for residential buildings. The subroutines expressed in 
#   this package are adopted from the CREST model developed and distributed by the Centre for Renewable Energy
#   Systems Technology at the University of Loughborough. The subroutines contained in this file are based on the
#   version of CREST described by:
#
#         Richardson, I., Thomson, M., Infield, D., & Clifford, C. (2010). Domestic electricity use: A high-resolution 
#         energy demand model. Energy and buildings, 42(10), 1878-1887.
#
#         For latest developments of the CREST model please see https://www.lboro.ac.uk/research/crest/demand-model/
#
# This software is a MODIFICATION and ADAPTATION of the CREST model licensed under the GNU General Public License 
# version 3. This modified software is documented in the publication:
#
#            Wills, A. D., Beausoleil-Morrison, I., & Ugursal, V. I. (2018). Adaptation and validation of an existing 
#            bottom-up model for simulating temporal and inter-dwelling variations of residential appliance and lighting
#            demands. Journal of Building Performance Simulation, 11(3), 350-368.
#
#===========================================================
#   Appliance_Lighting_Generator Copyright (C) 2019 <Name_of_Author>
#
#   Appliance_Lighting_Generator is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   Appliance_Lighting_Generator is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with Appliance_Lighting_Generator.  If not, see <https://www.gnu.org/licenses/>.
#=================================================================================================================
package OccupancyProfiles;
use strict;
use warnings;

our $VERSION = '1.00';

# Dependencies
#########################
use XML::Simple; # to parse the XML results files

# Set the package up to export the subroutines for local use within the calling perl script
require Exporter;
our @ISA = qw(Exporter);

# Place the routines that are to be automatically exported here
our @EXPORT = qw(getNewOccupancyProfile getLightingLoad getColdApplianceLoad ActiveStatParser getRandomBaseload getApplianceProfile);
# Place the routines that must be requested as a list following use in the calling script
our @EXPORT_OK = ();

##########################################################
# PUBLIC METHODS:
#   getNewOccupancyProfile: Generate occupancy profile
#   getLightingLoad: Generate aggregate lighting load profile
#   getColdApplianceLoad: Generate annual cold appliance demand profile
#   ActiveStatParser: Parses the activity statistics file data/activity_stats.csv
#   getApplianceProfile: Generates annual demand profile for generic appliance
#   getRandomBaseload: Generates random baseload from mean and standard deviation input [W]
#
##########################################################

# ====================================================================
# getNewOccupancyProfile
#       This subroutine generates the annual occupancy profile using 
#       a first-order Markov chain approach.
#
# INPUT     
#           hse_occ: integer number of occupants [1-5]
#           DayWeekStart: Starting day of the week [1=Sunday, 7=Saturday]
# OUTPUT    Occ: Array of integers indicating number of active occupants
#           at a 1-minute timestep     
#
# REFERENCES: - Richardson, I., Thomson, M., & Infield, D. (2008). A 
#               high-resolution domestic building occupancy model for 
#               energy demand simulations. Energy and buildings, 40(8),
#               1560-1566.
# ====================================================================
sub getNewOccupancyProfile {
    my ($hse_occ, $DayWeekStart) = @_;
    # INTERMEDIATES
    my @Occ_keys=qw(zero one two three four five six);

    # OUTPUT
    my @Occ;

    # Load the Initial-state occupancy data
    my $occ_strt = XMLin('data/occ_start_states.xml');
    # What is the initial day type? Weekday or weekend?
    my $sDayType =  _getWdWe($DayWeekStart);
    # Get the initial state of active occupants
    my $IniState = _setStartState($hse_occ,$occ_strt->{$sDayType}->{"$Occ_keys[$hse_occ]"});
    # Run the occupancy simulation
    my $Occ_ref = _OccupancySimulation($hse_occ,$IniState,$DayWeekStart); 
    @Occ = @$Occ_ref;

    return \@Occ;
};

# ====================================================================
# getLightingLoad
#       This subroutine generates the annual lighting consumption 
#       profile at a 1 minute timestep.
#
# INPUT     
#           sIrrPath: Path to irradiance data
#           fBulbs: Array holding wattage for each lamp [W]
#           fCalibrationScalar: Calibration scalar for lighting model
#           MeanThresh: Mean threshold for light ON [W/m2]
#           STDThresh: Std. dev for light ON [W/m2]
#           ref_Occ: Annual dwelling occupancy at 1 min timestep
# OUTPUT    Light: Annual lighting power at 1 min timestep [kW]
#           AnnPow: Annual power consumption of dwelling for lighting [kWh]
#
# REFERENCES: - Richardson, Thomson, Infield, Delahunty "Domestic Lighting:
#               A high-resolution energy demand model". Energy and Buildings, 
#               41, 2009.
# ====================================================================
sub getLightingLoad {
    # Read in inputs
    my ($sIrrPath, $fBulbs_ref, $fCalibrationScalar,$MeanThresh,$STDThresh,$ref_Occ) = @_;
    
    # Load the irradiance data
    my $Irr_ref =_getIrradiance($sIrrPath);
    my @Irr = @$Irr_ref;
    if (not defined $ref_Occ) {
        print "getLightingLoad: No occupancy profile has been provided, generating one\n";
        print "Enter number of occupants: ";
        my $iNumOccs = <STDIN>;
        chomp $iNumOccs;
        print "Enter starting day of the week [1=Sunday]: ";
        my $iStartDays = <STDIN>;
        chomp $iStartDays;
        $ref_Occ = getNewOccupancyProfile($iNumOccs,$iStartDays);
    };
    my @Occ = @$ref_Occ;
    # Set array for bulb wattages
    my @fBulbs = @$fBulbs_ref;
    
    if ($#Occ != $#Irr) {die "getLightingLoad: Number of occupancy and irradiance timesteps do not match\n"};
    
    # Set local variables
    my $Tsteps = scalar @Occ;
    my $SMALL = 1.0e-20;
    
    # Declare output
    my @Light=(0) x $Tsteps;

    # Determine the irradiance threshold of this house
    my $iIrradianceThreshold = _getMonteCarloNormalDistGuess($MeanThresh,$STDThresh);

    # Assign weightings to each bulb
    BULB: for (my $i=0;$i<=$#fBulbs;$i++) { # For each dwelling bulb
        # Determine this bulb's relative usage weighting
        my $fRand = rand();
        if ($fRand < $SMALL) {$fRand = $SMALL}; # Avoid domain errors
        my $fCalibRelUseW = -1*$fCalibrationScalar*log($fRand);

        # Calculate this bulb's usage for each timestep
        my $iTime=0;
        TIME: while ($iTime<=$#Occ) {
            # Is this bulb switched on to start with?
            # This concept is not implemented in this example.
            # The simplified assumption is that all bulbs are off to start with.
            
            # First determine if there are any occupants active for a switch-on event
            if ($Occ[$iTime]==0) { # No occupants, jump to next period
                $iTime++;
                next TIME;
            };
            # Determine if the bulb switch-on condition is passed
            # ie. Insuffient irradiance and at least one active occupant
            # There is a 5% chance of switch on event if the irradiance is above the threshold
            my $bLowIrradiance;
            if (($Irr[$iTime] < $iIrradianceThreshold) || (rand() < 0.05)) {
                $bLowIrradiance = 1;
            } else {
                $bLowIrradiance = 0;
            };
            
            # Get the effective occupancy for this number of active occupants to allow for sharing
            my $fEffectiveOccupancy = _getEffectiveOccupancy($Occ[$iTime]);

            # Check the probability of a switch on at this time
            if ($bLowIrradiance && (rand() < ($fEffectiveOccupancy*$fCalibRelUseW))) { # This is a switch on event
                # Determine how long this bulb is on for
                my $iLightDuration = _getLightDuration();
                
                DURATION: for (my $j=1;$j<=$iLightDuration;$j++) {
                    # Range Check
                    if ($iTime > $#Occ) {last TIME};
                    
                    # If there are no active occupants, turn off the light and increment the time
                    if ($Occ[$iTime] <=0) {
                        $iTime++;
                        next TIME;
                    };
                    
                    # Store the demand
                    $Light[$iTime] = $Light[$iTime]+($fBulbs[$i]/1000); # [kW]
                    
                    # Increment the time
                    $iTime++;
                }; # END DURATION
                
            } else { # The bulb remains off
                $iTime++;
            };
        }; # END TIME 
    }; # END BULB

    return(\@Light);
};

# ====================================================================
# getColdApplianceLoad
#       This subroutine uses a top-down approach to generate high-resolution
#       power draw profiles for cold appliances. The approach is similar to the 
#       cyclic load patterns found in Widen & Wackelgard 2010, although the ON/OFF
#       periods are assigned constant values for simplicity. 
#
# INPUT     UEC: Unit energy consumption [kWh/yr]
#           iCyclesPerYear: number of cycles per year
#           iMeanCycleLength: mean cycle length [min]
#           iRestartDelay: delay restart after cycle [min]
# OUTPUT    Cold: Annual electrical consumption profile of cold appliance [W]
# ====================================================================
sub getColdApplianceLoad {
    # Declare inputs
    my $UEC = shift;
    my $iCyclesPerYear = shift;
    my $iMeanCycleLength = shift;
    my $iRestartDelay = shift;
    
    # Local variables
    my $fPower; # Power draw when cycle is on [W]
    my $dCalibrate; # Calibration value to determine switch-on events
    my $iRestartDelayTimeLeft; # Counter to hold time left in the delay restart
    
    # Declare outputs
    my @Cold=(0) x 525600;
    my $cType;
    
    # Determine time appliance is running in a year [min]
    my $Trunning=$iCyclesPerYear*$iMeanCycleLength;
    
    # Determine the minutes in a year when an event can occur
    my $Ms = 525600-($Trunning+($iCyclesPerYear*$iRestartDelay));
    
    # Determine the mean time between start events [min]
    my $MT=$Ms/$iCyclesPerYear;
    $dCalibrate=1/$MT;
    
    # Estimate the cycle power [W]
    $fPower=($UEC/($Trunning/60))*1000;
    
    # ====================================================================
    # Begin generating profile
    # ====================================================================
    # Randomly delay the start of appliances that have a restart delay (e.g. cold appliances with more regular intervals)
    $iRestartDelayTimeLeft = int(rand()*$iRestartDelay*2); # Weighting is 2 just to provide some diversity
    my $iCycleTimeLeft = 0;
    my $iMinute = 0;
    
    MINUTE: while ($iMinute < 525600) { # For each minute of the year
        if ($iCycleTimeLeft <= 0 && $iRestartDelayTimeLeft > 0) { # If this appliance is off having completed a cycle (ie. a restart delay)
            # Decrement the cycle time left
            $iRestartDelayTimeLeft--;
        } elsif ($iCycleTimeLeft <= 0) { # Else if this appliance is off
            if (rand() < $dCalibrate) { # Start Appliance
                $Cold[$iMinute] = $fPower;
                $iRestartDelayTimeLeft = $iRestartDelay;
                $iCycleTimeLeft = $iMeanCycleLength-1;
            };
        } else { # The appliance is on
            $Cold[$iMinute] = $fPower;
            $iCycleTimeLeft--;
        };
        $iMinute++;
    }; # END MINUTE
    
    return(\@Cold);
};

# ====================================================================
# ActiveStatParser
#       This subroutine parses the activity probability profiles into
#       a hash
#
# INPUT     path: String, path to the activity stats file
# OUTPUT    Activity: HASH holding the activity data
# ====================================================================
sub ActiveStatParser {
    # Declare inputs
    my $path = shift;
    
    # Local variables
    my $fh;     # File handle
    my $day='wd';    # String to hold weekend or weekday
    my $NOcc;        # Number of occupants
    my $Act;         # String, activity type

    # Declare outputs
    my $Activity;
    
    
    open($fh,'<',$path) or die "Could not open file '$path' $!";
    # Read data line by line
    while (my $row = <$fh>) {
        chomp $row;
        my @data = split /,/, $row;
        if ($data[0]>0) {$day='we'};
        $NOcc = $data[1]; # Get active occupant count
        $Act = $data[2];  # Get the activity name
        @data = @data[ 3 .. $#data ]; # trim out the above data
        $Activity->{$day}->{"$NOcc"}->{$Act} = \@data; # Store the statistics
    };

    return($Activity);
};

# ====================================================================
# SetApplianceProfile
#   Load in the appliance inputs for sItem, and generate annual profile
#
# INPUT     Occ_ref: Reference to array holding annual occupancy data
#           MeanActOcc: fraction of time occupants are active [-]
#           sItem: String, name of the appliance
#           hApp: HASH holding appliance characteristics (See INTERMEDIATES)
#           Activity: HASH generated from subroutine ActiveStatParser
#           AppCalib: Global calibration scalar for appliances
#           DayWeekStart: day of the week [1=Sunday, 7=Saturday]
#
# OUTPUT    ThisApp: The power consumption for this appliance at a 1-minute timestep [W]
# ====================================================================
sub getApplianceProfile { 
    # INPUTS
    my $ref_Occ = shift @_; 
    my @Occ = @$ref_Occ; # Occupancy profile
    my $MeanActOcc = shift @_; # Mean active occupancy
    my $sItem = shift @_; # Name of appliance
    my $hApp = shift @_; # Appliance input hash
    my $Activity = shift @_;
    my $AppCalib = shift @_; # Calibration scalar for appliances
    my $DayWeekStart = shift @_; # Day of the week [1=Sunday]

    # OUTPUTS
    my @ThisApp;
    
    # INTERMEDIATES
    my $sUseProfile=$hApp->{'Use_Profile'}; # Type of usage profile
    my $iMeanCycleLength=$hApp->{'Mean_cycle_L'}; # Mean length of cycle [min]
    my $iCyclesPerYear=$hApp->{'Base_cycles'}*$AppCalib; # Calibrated number of cycles per year
    my $iStandbyPower=$hApp->{'Standby'}; # Standby power [W]
    my $iRatedPower=$hApp->{'Mean_Pow_Cyc'}; # Mean power per cycle [W]
    my $iRestartDelay=$hApp->{'Restart_Delay'}; # Delay restart after cycle [min]
    my $fAvgActProb=$hApp->{'Avg_Act_Prob'}; # Average activity probability [-]
    my $sOccDepend=$hApp->{'Act_Occ_Dep'}; # Active occupant dependent

    # Call the appliance simulation
    my $ThisApp_ref = _getApplianceProfilePrivate(\@Occ,$sItem,$sUseProfile,$iMeanCycleLength,$iCyclesPerYear,$iStandbyPower,$iRatedPower,$iRestartDelay,$fAvgActProb,$Activity,$MeanActOcc,$sOccDepend,$DayWeekStart);
    @ThisApp = @$ThisApp_ref;

	return(\@ThisApp);
};

sub getRandomBaseload { 
    # INPUTS
    my $mean = shift @_;
    my $stdDev = shift @_;

    # OUTPUTS
    my $fThisValue;
    
    $fThisValue = _getMonteCarloNormalDistGuess($mean,$stdDev);

	return($fThisValue);
};

##########################################################
#
# PRIVATE METHODS
#
##########################################################

# ====================================================================
# _getApplianceProfilePrivate
#       This subroutine uses generates the 
#       power draw profiles for cold appliances. The approach is similar to the 
#       cyclic load patterns found in Widen & Wackelgard 2010, although the ON/OFF
#       periods are assigned constant values for simplicity. 
#
# INPUT     Occ_ref: Reference to array holding annual occupancy data
#           item: String, name of the appliance
#           sUseProfile: String indicating the usage type
#           iMeanCycleLength: Mean length of each cycle [min]
#           iCyclesPerYear: Calibrated number of cycles per year
#           iStandbyPower: Standby power [W]
#           iRatedPower: Rated power during cycles [W]
#           iRestartDelay: Delay prior to starting a cycle [min]
#           fAvgActProb: Average activity probability [-]
#           ActStat: HASH holding the activity statistics
#           MeanActOcc: fraction of time occupants are active [-]
#           sOccDepend: Activity occupant presence dependent [YES/NO]
#           dayWeek: day of the week [1=Sunday, 7=Saturday]
# OUTPUT    Profile: The power consumption for this appliance at a 1-minute timestep [W]
# ====================================================================

sub _getApplianceProfilePrivate {
    # Declare inputs
    my $Occ_ref = shift;
    my @Occ = @$Occ_ref;
    my $item = shift;
    my $sUseProfile = shift;
    my $iMeanCycleLength = shift;
    my $iCyclesPerYear = shift;
    my $iStandbyPower = shift;
    my $iRatedPower = shift;
    my $iRestartDelay = shift;
    my $fAvgActProb = shift;
    my $ActStat = shift;
    my $MeanActOcc = shift;
    my $sOccDepend = shift;
    my $dayWeek = shift;
    
    # Local variables
    my $iCycleTimeLeft = 0;
    my $sDay;   # String to indicate weekday or weekend
    my $iYear=0; # Counter for minute of the year
    my $iRestartDelayTimeLeft = rand()*$iRestartDelay*2; # Randomly delay the start of appliances that have a restart delay
    my $bDayDep=1; # Flag indicating if appliance is dependent on weekend/weekday (default is true)
    my @PDF=(); # Array to hold the ten minute interval usage statistics for the appliance
    my $fAppCalib;
    my $bBaseL=0; # Boolean to state whether this appliance is a constant base load
    
    # Declare outputs
    my @Profile=($iStandbyPower) x 525600; # Initialize to constant standby power [W]
    
    # Determine the calibration scalar
    if ($iCyclesPerYear > 0) {
        $fAppCalib = _applianceCalibrationScalar($iCyclesPerYear,$iMeanCycleLength,$MeanActOcc,$iRestartDelay,$sOccDepend,$fAvgActProb);
    } else { # This is just a constant load
        $bBaseL=1;
    };
    
    if ($bBaseL < 1) { # Not a baseload appliance, calculate the timestep data
        # Make the rated power variable over a normal distribution to provide some variation [W]
        $iRatedPower = _getMonteCarloNormalDistGuess($iRatedPower,($iRatedPower/10));
        
        # Determine if appliance operation is weekday/weekend dependent
        if($sUseProfile =~ m/Active_Occ/ || $sUseProfile =~ m/Level/) {$bDayDep=0};
        
        # Start looping through each day of the year
        DAY: for(my $iDay=1;$iDay<=365;$iDay++) {
            my $DayStat; # HASH reference for current day
            
            # If this appliance depends on day type, get the relevant activity statistics
            if($bDayDep) { 
                if($dayWeek>7){$dayWeek=1};
                if($dayWeek == 1 || $dayWeek == 7) { # Weekend
                    $sDay = 'we';
                } else { # Weekday
                    $sDay = 'wd';
                };
                $DayStat=$ActStat->{$sDay};
            };
            
            # For each 10 minute period of the day
            TEN_MIN: for(my $iTenMin=0;$iTenMin<144;$iTenMin++) {
                # For each minute of the day
                MINUTE: for(my $iMin=0;$iMin<10;$iMin++) {
                    # If this appliance is off having completed a cycle (ie. a restart delay)
                    if ($iCycleTimeLeft <= 0 && $iRestartDelayTimeLeft > 0) {
                        $iRestartDelayTimeLeft--; # Decrement the cycle time left
                        
                    # Else if this appliance is off    
                    } elsif ($iCycleTimeLeft <= 0) {
                        # There must be active occupants, or the profile must not depend on occupancy for a start event to occur
                        if (($Occ[$iYear] > 0 && $sUseProfile !~ m/Custom/) || $sUseProfile =~ m/Level/) {
                            # Variable to store the event probability (default to 1)
                            my $dActivityProbability = 1;
                            
                            # For appliances that depend on activity profiles
                            if (($sUseProfile !~ m/Level/) && ($sUseProfile !~ m/Active_Occ/) && ($sUseProfile !~ m/Custom/)) {
                                # Get the probability for this activity profile for this time step
                                my $CurrOcc = $Occ[$iYear]; # Current occupancy this timestep
                                my $Prob_ref = $DayStat->{"$CurrOcc"}->{$sUseProfile};
                                my @Prob=@$Prob_ref;
                                $dActivityProbability = $Prob[$iTenMin];
                            };
                            
                            # If there is seasonal variation, adjust the calibration scalar
                            if ($item =~ m/^Clothes_Dryer_Elec$/) { # Dryer usage varies seasonally
                                my $fAmp =  20.5; # based on difference in average loads/week winter/summer (SHEU 2011);
                                my $fModCyc = ($fAmp*sin(((2*3.14159265*$iDay)/365)-((1241*3.14159265)/730)))+$iCyclesPerYear;
                                $fAppCalib = _applianceCalibrationScalar($fModCyc,$iMeanCycleLength,$MeanActOcc,$iRestartDelay,$sOccDepend,$fAvgActProb); #Adjust the calibration
                            }; # elsif .. (Other appliances)
                            
                            # Check the probability of a start event
                            if (rand() < ($fAppCalib*$dActivityProbability)) {
                                ($iCycleTimeLeft,$iRestartDelayTimeLeft,$Profile[$iYear]) = _startAppliance($item,$iRatedPower,$iMeanCycleLength,$iRestartDelay,$iStandbyPower);
                            };
                        } elsif ($sUseProfile =~ m/Custom/) {
                            # PLACE CODE HERE FOR CUSTUM APPLIANCE BEHAVIOUR
                            # THIS CODE BLOCK DETERMINES HOW CUSTOM APPLIANCE IS SWITCHED ON
                            # ($iCycleTimeLeft,$iRestartDelayTimeLeft,$Profile[$iYear]) = StartCustom($item,$iRatedPower,$iMeanCycleLength,$iRestartDelay,$iStandbyPower);
                        };
    
                    # The appliance is on - if the occupants become inactive, switch off the appliance
                    } else {
                        if (($Occ[$iYear] == 0) && ($sUseProfile !~ m/Level/) && ($sUseProfile !~ m/Act_Laundry/) && ($item !~ m/Dishwasher/) && ($sUseProfile !~ m/Custom/)) {
                            # Do nothing. The activity will be completed upon the return of the active occupancy.
                            # Note that LEVEL means that the appliance use is not related to active occupancy.
                            # Note also that laundry appliances do not switch off upon a transition to inactive occupancy.
                            # The original CREST model was modified to include dishwashers here as well
                        } elsif ($sUseProfile !~ m/Custom/) { 
                            # Set the power
                            $Profile[$iYear]=_getPowerUsage($item,$iRatedPower,$iCycleTimeLeft,$iStandbyPower);
                            
                            # Decrement the cycle time left
                            $iCycleTimeLeft--;
                        } else { # Custum Use profile
                            # PLACE CODE HERE FOR CUSTUM APPLIANCE BEHAVIOUR
                            # THIS CODE BLOCK DETERMINES HOW CUSTOM APPLIANCE BEHAVES 
                            # WHILE IT IS ON
                            # $Profile[$iYear]=GetCustomUsage($item,$iRatedPower,$iCycleTimeLeft,$iMeanCycleLength,$iStandbyPower);
                        };
                    };
    
                    $iYear++; # Increment the minute of the year
                }; # END MINUTE
            }; # END TEN_MIN
            $dayWeek++; # Increment the day of the week
        }; # END DAY
    }; # END CALCS

    return(\@Profile);
};

sub _getWdWe {
    my $DayWeekStart = shift;
    if($DayWeekStart<1 || $DayWeekStart>7) {die "_getWdWe: $DayWeekStart is not a valid day of the week\n";}
    my $sDayType;
    if($DayWeekStart<2 || $DayWeekStart>6) {
        $sDayType = 'we';
    } else {
        $sDayType = 'wd';
    };
    
    return $sDayType;
};

# ====================================================================
# _setStartState
#       This subroutine randomly assigns an occupancy start state for the 
#       dwelling.
#
# INPUT     numOcc: number of occupants in the house
#           pdf: probability distribution function HASH (refen
# OUTPUT    StartActive: number of active occupants 
#
# REFERENCES: - Richardson, Thomson, Infield, Clifford "Domestic Energy Use:
#               A high-resolution energy demand model". Energy and Buildings, 
#               42, 2010.
#             
# ====================================================================

sub _setStartState {
	# Read in inputs
    my ($numOcc, $pdf) = @_;
    
    # Local variables
    my $fRand = rand();
    my $fCumulativeP = 0;
    my $StartActive;
    my @ky = qw(zero one two three four five six);
    
    SET_IT: for (my $i = 0; $i<=6 && exists $pdf->{"$ky[$i]"}; $i++) {
        $fCumulativeP = $fCumulativeP + $pdf->{"$ky[$i]"};
        if ($fRand < $fCumulativeP) {
            $StartActive = $i;
            last SET_IT;
        };
    }; 
    if (!defined $StartActive) {$StartActive = 0};
    
    return ($StartActive);
};

# ====================================================================
# OccupancySimulation
#       This subroutine generates the annual occupancy profile at a 1 
#       minute timestep.
#
# INPUT     numOcc: number of occupants in the house
#           initial: initial number of active occupants for the set
#           dayWeek: initial day of the week [1=Sun, 7=Sat]
# OUTPUT    StartActive: number of active occupants 
#
# REFERENCES: - Richardson, Thomson, Infield, Clifford "Domestic Energy Use:
#               A high-resolution energy demand model". Energy and Buildings, 
#               42, 2010.
#             
# ====================================================================

sub _OccupancySimulation {
	# Read in inputs
    my ($numOcc, $initial, $dayWeek) = @_;
    
    # Local variables
    my @Occ = ($initial) x 10; # Array holding number of active occupants in dwelling per minute
    my $bStart=1;
    
    # Check to see if occupancy exceeds model limits
    if ($numOcc>5) { # Reduce the number of occupants to 5
        $numOcc=5;
        print "WARNING in _OccupancySimulation: $numOcc exceeds max occupancy of 5. Reset to 5\n";
    };
    
    # Load both transition matrices
    my @TRmatWD=(); # Array to hold weekday transition matrix
    my @TRmatWE=(); # Array to hold weekend transition matrix
    
    my $WDfile = "data/tpm" . "$numOcc" . "_wd.csv";
    open my $fh, '<', $WDfile or die "Cannot open $WDfile: $!";
    while (my $dat = <$fh>) {
        chomp $dat;
        push(@TRmatWD,$dat);
    };
    @TRmatWD = @TRmatWD[ 1 .. $#TRmatWD ]; # Trim out header
    close $fh;
    
    my $WEfile = "data/tpm" . "$numOcc" . "_we.csv";
    open my $fhdl, '<', $WEfile or die "Cannot open $WEfile: $!";
    while (my $dat = <$fhdl>) {
        chomp $dat;
        push(@TRmatWE,$dat);
    };
    @TRmatWE = @TRmatWE[ 1 .. $#TRmatWE ]; # Trim out header
    close $fhdl;
    
    YEAR: for (my $i=1; $i<=365; $i++) { # for each day of the year
        # Determine which transition matrix to use
        my $tDay; 
        my @TRmat;
        if ($dayWeek>7){$dayWeek=1};
        if ($dayWeek == 1 || $dayWeek == 7) {
            @TRmat = @TRmatWE;
        } else { 
            @TRmat = @TRmatWD;
        };

        if ($bStart) { # first call, first 10 minutes don't matter
            @TRmat = @TRmat[ 7 .. $#TRmat ];
            $bStart=0;
        };
        DAY: for (my $j=0; $j<=$#TRmat; $j=$j+7) { # Cycle through each period in the matrix
            my $current = $Occ[$#Occ]; # Current occupancy
            # Find the appropriate distribution data
            my $k=$j+$current;
            my $dist = $TRmat[$k];
            chomp $dist;
            my @data = split /,/, $dist;
            @data = @data[ 2 .. $#data ]; # Trim out the index values
            my $fCumulativeP=0; # Cumulative probability for period
            my $fRand = rand();
            my $future=0; # future occupancy
            TEN: while ($future < $numOcc) {
                $fCumulativeP=$fCumulativeP+$data[$future];
                if ($fRand < $fCumulativeP) {
                    last TEN;
                };
                $future++;
            }; # END TEN
            
            # Update the Occupancy array
            for (my $m=0; $m<10; $m++) { # This will be the occupancy for the next ten minutes
                push(@Occ,$future);
            };
        }; # END DAY
        $dayWeek++;
    }; # END YEAR 

    return (\@Occ);
};

# ====================================================================
# GetIrradiance
#       This subroutine loads the irradiance data and returns it 
#
# INPUT     file: path and file name of input
# OUTPUT    Irr: Array holding the irradiance data [W/m2]
#
# ====================================================================

sub _getIrradiance {
    # Read in inputs
    my ($file) = @_;
    
    # Declare output
    my @Irr=();
    
    open my $fh, '<', $file or die "Cannot open $file: $!";
    my $i=0;
    RAD: while (my $dat = <$fh>) {
            if ($i<2) { # Header data, skip
                $i++;
                next RAD;
            };
            chomp $dat;
            my @temp = split /\t/, $dat,2;
            $temp[1] = sprintf("%.10g", $temp[1]);
            push(@Irr, $temp[1]); 
    }; # END RAD
    close $fh;
    
    if(($#Irr+1)<525600) {die " ERROR _getIrradiance: Irradiance file $file does not have enough records (<525600)\n";}
    
    until(($#Irr+1)==525600) {pop(@Irr);}

    return(\@Irr);
};

# ====================================================================
# _getEffectiveOccupancy
#   This subroutine determines the effective occupancy
# ====================================================================
sub _getEffectiveOccupancy {
    my ($Occ) = @_; # Number of occupants active

    my $EffOcc;
    
    if ($Occ==0) {
        $EffOcc=0;
    } elsif ($Occ==1) {
        $EffOcc=1;
    } elsif ($Occ==2) {
        $EffOcc=1.528;
    } elsif ($Occ==3) {
        $EffOcc=1.694;
    } elsif ($Occ==4) {
        $EffOcc=1.983;
    } elsif ($Occ==5) {
        $EffOcc=2.094;
    } else {
        die "Number of occupants $Occ exceeds model limits";
    };

    return $EffOcc;
};

# ====================================================================
# _getLightDuration
#   Determines the lighting event duration
#   REFERENCE: - Stokes, Rylatt, Lomas "A simple model of domestic lighting
#                demand". Energy and Buildings, 36(2), 2004. 
# ====================================================================
sub _getLightDuration {

    # Decalre the output
    my $Duration;
    
    # Lighting event duration model data
    my $cml;
    $cml->{'1'}->{'lower'}=1;
    $cml->{'1'}->{'upper'}=1;
    $cml->{'1'}->{'cml'}=0.111111111;
    
    $cml->{'2'}->{'lower'}=2;
    $cml->{'2'}->{'upper'}=2;
    $cml->{'2'}->{'cml'}=0.222222222;
    
    $cml->{'3'}->{'lower'}=3;
    $cml->{'3'}->{'upper'}=4;
    $cml->{'3'}->{'cml'}=0.222222222;
    
    $cml->{'4'}->{'lower'}=5;
    $cml->{'4'}->{'upper'}=8;
    $cml->{'4'}->{'cml'}=0.333333333;
    
    $cml->{'5'}->{'lower'}=9;
    $cml->{'5'}->{'upper'}=16;
    $cml->{'5'}->{'cml'}=0.444444444;
    
    $cml->{'6'}->{'lower'}=17;
    $cml->{'6'}->{'upper'}=27;
    $cml->{'6'}->{'cml'}=0.555555556;
    
    $cml->{'7'}->{'lower'}=28;
    $cml->{'7'}->{'upper'}=49;
    $cml->{'7'}->{'cml'}=0.666666667;
    
    $cml->{'8'}->{'lower'}=50;
    $cml->{'8'}->{'upper'}=91;
    $cml->{'8'}->{'cml'}=0.888888889;
    
    $cml->{'8'}->{'lower'}=92;
    $cml->{'8'}->{'upper'}=259;
    $cml->{'8'}->{'cml'}=1.0;
    
    my $r_one = rand();
    
    RANGE: for (my $j=1;$j<=9;$j++) {
        if ($r_one < $cml->{"$j"}->{'cml'}) {
            my $r_two = rand();
            $Duration = ($r_two * ($cml->{"$j"}->{'upper'}-$cml->{"$j"}->{'lower'}))+$cml->{"$j"}->{'lower'};
            $Duration = sprintf "%.0f", $Duration; # Round to nearest integer
            last RANGE;
        };
    }; # END RANGE

    return $Duration;
};

# ====================================================================
# _applianceCalibrationScalar
#   This subroutine determines the appliance calibration scalar
# ====================================================================
sub _applianceCalibrationScalar {
    
    # Declare inputs
    my $iCyclesPerYear = shift;
    my $iMeanCycleLength = shift;
    my $MeanActOcc = shift;
    my $iRestartDelay = shift;
    my $sOccDepend = shift;
    my $fAvgActProb = shift;
    
    # Declare outputs
    my $fAppCalib;

    # Determine the calibration scalar for this appliance
    my $iTimeRunYr = $iCyclesPerYear*$iMeanCycleLength; # Time spent running per year [min]
    if ($iTimeRunYr>525600) { # Not possible to have this many cycles
        # Warn the user
        print "WARNING: Appliance with $iCyclesPerYear cycles per year and cycle length $iMeanCycleLength min\n";
        print "         Computed running time exceeds time in year. Setting time spent running to 70% of year.\n";
        $iCyclesPerYear = floor((525600*0.7)/$iMeanCycleLength);
        $iTimeRunYr = $iCyclesPerYear*$iMeanCycleLength;
    };
    my $iMinutesCanStart; # Minutes in a year when an event can start
    if($sOccDepend =~ m/YES/) { # Appliance is active occupant dependent
        $iMinutesCanStart = (525600*$MeanActOcc)-($iTimeRunYr+($iCyclesPerYear*$iRestartDelay));
    } else { # Appliance is not active occupant dependent
        $iMinutesCanStart = 525600-($iTimeRunYr+($iCyclesPerYear*$iRestartDelay));
    };
    if ($iMinutesCanStart<=0) { # There is no minutes when this appliance can start
        print "WARNING: Appliance has $iMinutesCanStart min in the year which it can start\n";
        print "         Setting mean start time between events to 1 min\n";
        $iMinutesCanStart=$iCyclesPerYear;
    };
    my $fMeanCanStart=$iMinutesCanStart/$iCyclesPerYear; # Mean time between start events given occupancy [min]
    my $fLambda = 1/$fMeanCanStart;
    $fAppCalib = $fLambda/$fAvgActProb; # Calibration scalar
    
    return($fAppCalib);
};

# ====================================================================
# _startAppliance
#   Start a cycle for the current appliance
# ====================================================================
sub _startAppliance {
    
    # Declare inputs
    my $item = shift;
    my $iRatedPower = shift;
    my $iMeanCycleLength = shift;
    my $iRestartDelay=shift;
    my $iStandbyPower=shift;

    # Declare outputs
    my $iCycleTimeLeft = _cycleLength($item,$iMeanCycleLength);
    my $iRestartDelayTimeLeft=$iRestartDelay;
    my $iPower = _getPowerUsage($item,$iRatedPower,$iCycleTimeLeft,$iStandbyPower);
    
    $iCycleTimeLeft--;

    return($iCycleTimeLeft,$iRestartDelayTimeLeft,$iPower);
};

# ====================================================================
# _getPowerUsage
#   Some appliances have a custom (variable) power profile depending on the time left
# ====================================================================
sub _getPowerUsage {
    
    # Declare inputs
    my $item = shift;
    my $iRatedPower = shift;
    my $iCycleTimeLeft = shift;
    my $iStandbyPower = shift;

    # Declare outputs (Default to rated power)
    my $PowerUsage=$iRatedPower;
    
    if($item =~ m/^Clothes_Washer$/) { # If the appliance is a washer (peak 500 W)
        $PowerUsage=_getPowerWasher($iRatedPower,$iCycleTimeLeft,$iStandbyPower);
    } elsif($item =~ m/^Clothes_Dryer_Elec$/) { # If the appliance is a dryer (peak 5535 W)
        $PowerUsage=_getPowerDryer($iRatedPower,$iCycleTimeLeft,$iStandbyPower);
    } elsif($item =~ m/^Dishwasher$/) { # If the appliance is a dishwasher (peak 1300 W)
        $PowerUsage=_getPowerDish($iRatedPower,$iCycleTimeLeft,$iStandbyPower);
    };

    return($PowerUsage);
};

# ====================================================================
# _getPowerDryer
#   This subroutine generates the dryer profile. Note that it is a fixed
#   profile. The profile is a 73 minute cycle which consumes 7935 kJ of
#   energy. The profile is taken from H12 from the paper:
# REFERENCES: - Saldanha, Beausoleil-Morrison "Measured end-use electric load
#               profiles for 12 Canadian houses at high temporal resolution."
#               Energy and Buildings, 49, 2012.
#   The model of the dryer is Kenmore 110.C64852301
# ====================================================================
sub _getPowerDryer {
    
    # Declare inputs
    my $iRatedPower = shift; # Peak power demand
    my $iCycleTimeLeft = shift;
    my $iStandbyPower = shift;

    # Declare outputs
    my $PowerUsage;
    
    # Declare local variables
    my @Profile = (0.674796748,0.951219512,0.991869919,0.967479675,0.991869919,1,
    1,1,1,0.991869919,0.991869919,0.983739837,0.975609756,0.975609756,0.528455285,
    0.203252033,0.951219512,0.951219512,0.691056911,0.056910569,0.739837398,
    0.967479675,0.349593496,0.056910569,0.74796748,0.804878049,0.056910569,
    0.056910569,0.341463415,0.333333333,0.056910569,0.056910569,0.056910569,
    0.056910569,0.056910569,0.056910569,0.048780488,0.056910569,0.056910569,
    0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,
    0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,
    0.06504065,0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,
    0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,0.056910569,
    0.056910569,0.056910569,0.06504065,0.056910569,0.056910569,0.06504065,
    0.056910569,0.056910569,0.056910569,0.06504065,0.056910569,0.032520325); # 1-minute profile for dryer
    my $iTotalCycleTime = scalar @Profile;
    my $index = $iTotalCycleTime - $iCycleTimeLeft;
    
    if (($index<0) || ($index>$#Profile)) {
        $PowerUsage = $iStandbyPower;
    } else {
        $PowerUsage=$iRatedPower*$Profile[$index];
    };
    
    return($PowerUsage);
};

# ====================================================================
# _getPowerWasher
#   This subroutine generates the clothes washer profile. Note that it is a
#   fixed profile. The profile is a 40 minute cycle. This is measured data
#   from a top-loading washing maching of approximately 1990's vintage
#   Data was measured using a WattsUp? Pro at 1-min timesteps
# ====================================================================
sub _getPowerWasher {
    
    # Declare inputs
    my $iRatedPower = shift; # Peak power demand
    my $iCycleTimeLeft = shift;
    my $iStandbyPower = shift;

    # Declare outputs
    my $PowerUsage;
    
    # Declare local variables
    my @Profile = (0.008748413,0.008748413,0.008748413,0.008748413,0.008748413,
    0.956681247,0.916325667,0.892620291,0.853816848,0.853675744,0.860166502,
    0.872865811,0.847608297,0.589247919,0.59136447,0.595174263,0.591646677,
    0.593904332,0.583885988,0.54197827,0.498377311,0.786510512,0.730915761,
    0.008607309,0.008607309,0.008748413,0.008607309,0.008607309,0.838295471,
    0.843798504,0.828418231,0.874276845,0.535487512,0.497954,1,0.761535205,
    0.725836038,0.705658247,0.698603076,0.688725836); # 1-minute profile for washer
    my $iTotalCycleTime = scalar @Profile;
    my $index = $iTotalCycleTime - $iCycleTimeLeft;

    if (($index<0) || ($index>$#Profile)) {
        $PowerUsage = $iStandbyPower;
    } else {
        $PowerUsage=$iRatedPower*$Profile[$index];
    };
    
    return($PowerUsage);
};

# ====================================================================
# _getPowerDish
#   This subroutine generates the dishwasher profile. The profile is a 
#   124 minute cycle which consumes 5900 kJ of energy. The profile is 
#   scaled based on the rated input power. The profile is taken from
#   H12 from the paper:
# REFERENCES: - Saldanha, Beausoleil-Morrison "Measured end-use electric load
#               profiles for 12 Canadian houses at high temporal resolution."
#               Energy and Buildings, 49, 2012.
#   The model of the dishwasher is Kenmore 665.13732K601 
# ====================================================================
sub _getPowerDish {
    
    # Declare inputs
    my $iRatedPower = shift; # Peak power demand
    my $iCycleTimeLeft = shift;
    my $iStandbyPower = shift;

    # Declare outputs
    my $PowerUsage;
    
    # Declare local variables
    my @Profile = (0.153846154,0.153846154,0.153846154,0.153846154,0.153846154,
    0.153846154,0.153846154,0.153846154,0.153846154,0.153846154,0.153846154,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,0.215384615,
    0.215384615,0.215384615); # 1-minute profile for dishwasher
    my $iTotalCycleTime = scalar @Profile;
    my $index = $iTotalCycleTime - $iCycleTimeLeft;
    
    if (($index<0) || ($index>$#Profile)) {
        $PowerUsage = $iStandbyPower;
    } else {
        $PowerUsage=$iRatedPower*$Profile[$index];
    };
    
    return($PowerUsage);
};

# ====================================================================
# _cycleLength
#   Determine the cycle length of the appliance
# ====================================================================
sub _cycleLength {
    
    # Declare inputs
    my $item = shift;
    my $iMeanCycleLength = shift;

    # Declare outputs
    my $CycleLen=$iMeanCycleLength;
    
    if($item =~ m/TV$/) { # If the appliance is a television
        # The cycle length is approximated by the following function
        # Average time Canadians spend watching TV is 2.1 hrs (Stats Can: General 
        # social survey (GSS), average time spent on various activities for the 
        # population aged 15 years and over, by sex and main activity. 2010)
        my $fRando = rand();
        if ($fRando > 0.999) {$fRando=0.995};
        $CycleLen=int($iMeanCycleLength * ((0 - log(1 - $fRando)) ** 1.1));
    } elsif ($item =~ m/^Game_Console$/) {
        # The cycle length is approximated by the following function
        my $fRando = rand();
        if ($fRando > 0.999) {$fRando=0.995};
        $CycleLen=int($iMeanCycleLength * ((0 - log(1 - $fRando)) ** 1.1));
    # Currently these profiles are fixed. Override user input to length of
    # each static cycle
    } elsif ($item =~ m/Clothes_Washer/) {
        $CycleLen=40;
    } elsif ($item =~ m/^Clothes_Dryer_Elec$/) {
        $CycleLen=75;
    } elsif ($item =~ m/^Dishwasher/) {
        $CycleLen=124;
    };

    return($CycleLen);
};

# ====================================================================
# _getMonteCarloNormalDistGuess
#   This subroutine randomly selects a value from a normal distribution.
#   Inputs are the mean and standard deviation
# ====================================================================
sub _getMonteCarloNormalDistGuess {
    my ($dMean, $dSD) = @_;
    my $iGuess=0;
    my $bOk;
    
    if($dMean == 0) {
        $bOk = 1;
    } else {
        $bOk = 0;
    };
    
    while (!$bOk) {
        $iGuess = (rand()*($dSD*8))-($dSD*4)+$dMean;
        my $px = (1/($dSD * sqrt(2*3.14159))) * exp(-(($iGuess - $dMean) ** 2) / (2 * $dSD * $dSD));

        if ($px >= rand()) {$bOk=1};

    };

    return $iGuess;
};

1;