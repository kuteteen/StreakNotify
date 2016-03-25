/*
This tweak notifies a user when a snapchat streak with another friend is running down in time. It also tells a user how much time is remanining in their feed. Customizable with a bunch of settings, custom time, custom friends, and even preset values that you can enable with a switch in preferences 
 
*/


#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "Interfaces.h"

#define kiOS7 (kCFCoreFoundationVersionNumber >= 847.20 && kCFCoreFoundationVersionNumber <= 847.27)
#define kiOS8 (kCFCoreFoundationVersionNumber >= 1140.10 && kCFCoreFoundationVersionNumber >= 1145.15)
#define kiOS9 (kCFCoreFoundationVersionNumber == 1240.10)


static NSDictionary* prefs = nil;
static CFStringRef applicationID = CFSTR("com.YungRaj.streaknotify");

NSString *kSnapDidSendNotification = @"snapDidSendNotification";

static void LoadPreferences() {
    prefs = [NSMutableDictionary dictionaryWithContentsOfFile: @"/var/mobile/Library/Preferences/com.YungRaj.streaknotify.plist"];
    
}

static void SizeLabelToRect(UILabel *label, CGRect labelRect){
    /* utility method to make sure that the label's size doesn't truncate the text that it is supposed to display */
    label.frame = labelRect;
    
    int fontSize = 15;
    int minFontSize = 3;
    
    CGSize constraintSize = CGSizeMake(label.frame.size.width, MAXFLOAT);
    
    do {
        label.font = [UIFont fontWithName:label.font.fontName size:fontSize];
        
        CGRect textRect = [[label text] boundingRectWithSize:constraintSize
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName:label.font}
                                                     context:nil];
        
        CGSize labelSize = textRect.size;
        if( labelSize.height <= label.frame.size.height )
            break;
        
        fontSize -= 0.5;
        
    } while (fontSize > minFontSize);
}


static NSArray* GetFriendDisplayNames(){
    /* provide display names for each friend into an array */
    
    NSMutableArray *names = [[NSMutableArray alloc] init];
    Manager *manager = [%c(Manager) shared];
    User *user = [manager user];
    Friends *friends = [user friends];
    for(Friend *f in [friends getAllFriends]){
        NSString *displayName = [f display];
        [names addObject:displayName];
    }
    return names;
}

/* will be used later if I decide to give the user the option to only show friends with streaks on PSLinkList
*/
/*static NSArray* GetFriendDisplayNamesWithStreaksOnly(){
    // provide display names for friends with streaks only
    
    NSMutableArray *names = [[NSMutableArray alloc] init];
    Manager *manager = [%c(Manager) shared];
    User *user = [manager user];
    Friends *friends = [user friends];
    for(Friend *f in [friends getAllFriends]){
        if([f snapStreakCount]>2){
            NSString *displayName = [f display];
            [names addObject:displayName];
        }
    }
    return names;
}*/


static NSString* GetTimeRemaining(Friend *f, SCChat *c){
    /* good utility method to figure out the time remaining for the streak, might want to add a few fixes, because we are only assuming that the time remaining is 24 hours after the last sent snap when it could be different. We don't really know how the snap streaks start and end at the server level because it does all the work for figuring that out. As far as I've seen by reverse engineering the app, the app can only request to the server to up or even change the snap streak count...
     */
    if(!f || !c){
        return @"";
    }
    
    NSDate *date = [NSDate date];
    Snap *lastSnap = [c lastSnap];
    
    if(!lastSnap){
        return @"";
    }
    
    NSDate *latestSnapDate = [lastSnap timestamp];
    int daysToAdd = 1;
    NSDate *latestSnapDateDayAfter = [latestSnapDate dateByAddingTimeInterval:60*60*24*daysToAdd];
    NSCalendar *gregorianCal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
    NSUInteger unitFlags = NSSecondCalendarUnit | NSMinuteCalendarUnit |NSHourCalendarUnit | NSDayCalendarUnit;
    NSDateComponents *components = [gregorianCal components:unitFlags
                                                fromDate:date
                                                  toDate:latestSnapDateDayAfter
                                                 options:0];
    NSInteger day = [components day];
    NSInteger hour = [components hour];
    NSInteger minute = [components minute];
    NSInteger second = [components second];
    
    if(day<0 || hour<0 || minute<0 || second<0){
        return @"Limited";
        /*this means that the last snap + 24 hours later is earlier than the current time... and a streak is still valid assuming that the function that called this checked for a valid streak
         again this could happen because we don't know how the streaks start and end because as far as I've know the server does all the work for that... might have to ask someone more intelligent to figure out a way around this
         */
    }
    
    if(day){
        return [NSString stringWithFormat:@"%ldd",(long)day];
    }else if(hour){
        return [NSString stringWithFormat:@"%ld hr",(long)hour];
    }else if(minute){
        return [NSString stringWithFormat:@"%ld m",(long)minute];
    }else if(second){
        return [NSString stringWithFormat:@"%ld s",(long)second];
    }else{
        return @"Unknown";
    }
    
}

static void ScheduleNotification(NSDate *snapDate,
                                 NSString *displayName,
                                 float seconds,
                                 float minutes,
                                 float hours){
    // schedules the notification and makes sure it isn't before the current time
    float t = hours ? hours : minutes ? minutes : seconds;
    NSString *time =  hours ? @"hours" : minutes ? @"minutes" : @"seconds";
    NSDate *notificationDate =
    [[NSDate alloc] initWithTimeInterval:60*60*24 - 60*60*hours - 60*minutes - seconds
                               sinceDate:snapDate];
    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.fireDate = notificationDate;
    notification.alertBody = [NSString stringWithFormat:@"Keep streak with %@. %ld %@ left!",displayName,(long)t,time];
    NSDate *latestDate = [notificationDate laterDate:[NSDate date]];
    if(latestDate==notificationDate){
        [[UIApplication sharedApplication] scheduleLocalNotification:notification];
    }
}

static void ResetNotifications(){
    /* ofc set the local notifications based on the preferences, good utility function that is commonly used in the tweak
     */
    [[UIApplication sharedApplication] cancelAllLocalNotifications];
    Manager *manager = [%c(Manager) shared];
    User *user = [manager user];
    Friends *friends = [user friends];
    SCChats *chats = [user chats];
    
    for(SCChat *chat in [chats allChats]){
        NSDate *snapDate = [[chat lastSnap] timestamp];
        Friend *f = [friends friendForName:[chat recipient]];
        NSString *lastSnapSender = [[chat lastSnap] sender];
        NSString *friendName = [f name];
        
        if([f snapStreakCount]>2 && [lastSnapSender isEqual:friendName]){
            NSString *displayName = [friends displayNameForUsername:[chat recipient]];
            if([prefs[@"kTwelveHours"] boolValue]){
                ScheduleNotification(snapDate,displayName,0,0,12);
                
            } if([prefs[@"kFiveHours"] boolValue]){
                ScheduleNotification(snapDate,displayName,0,0,5);
                
            } if([prefs[@"kOneHour"] boolValue]){
                ScheduleNotification(snapDate,displayName,0,0,1);
                
            } if([prefs[@"kTenMinutes"] boolValue]){
                ScheduleNotification(snapDate,displayName,0,10,0);
            }
            
            float seconds = [prefs[@"kCustomSeconds"] floatValue];
            float minutes = [prefs[@"kCustomMinutes"] floatValue];
            float hours = [prefs[@"kCustomHours"] floatValue] ;
            if(hours || minutes || seconds){
                ScheduleNotification(snapDate,displayName,seconds,minutes,hours);
            }
        }
    }
}

%group iOS9

%hook MainViewController

-(void)viewDidLoad{
    
    /* easy way to tell the user that they haven't configured any settings, let's make sure that they know that so that can customize how they want to their notifications for streaks to work
     */
    %orig();
    if(!prefs) {
        UIAlertController *controller =
        [UIAlertController alertControllerWithTitle:@"StreakNotify"
                                            message:@"You haven't selected any preferences yet in Settings, use defaults?"
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancel =
        [UIAlertAction actionWithTitle:@"Cancel"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction* action){
                                   exit(0);
                               }];
        UIAlertAction *ok =
        [UIAlertAction actionWithTitle:@"Ok"
                                 style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction* action){
                                   prefs = @{@"kTwelveHours" : @NO,
                                             @"kFiveHours" : @NO,
                                             @"kOneHour" : @NO,
                                             @"kTenMinutes" : @NO,
                                             @"kCustomHours" : @"0",
                                             @"kCustomMinutes" : @"0",
                                             @"kCustomSeconds" : @"0"};
                               }];
        [controller addAction:cancel];
        [controller addAction:ok];
        [self presentViewController:controller animated:NO completion:nil];
        
        
    }
}

%end

%hook AppDelegate

-(BOOL)application:(UIApplication*)application willFinishLaunchingWithOptions:(NSDictionary*)launchOptions{
    
    NSLog(@"Running server on the app (tweak)");
    
    CPDistributedNotificationCenter* notificationCenter;
    notificationCenter = [CPDistributedNotificationCenter centerNamed:@"appToDaemon"];
    [notificationCenter runServer];
    [notificationCenter retain];
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(daemonDidStartListening:)
               name:@"CPDistributedNotificationCenterClientDidStartListeningNotification"
             object:notificationCenter];
    
    return %orig();

}

-(BOOL)application:(UIApplication*)application
didFinishLaunchingWithOptions:(NSDictionary*)launchOptions{
    
    /* just makes sure that the app is registered for local notifications, might be implemented in the app but haven't explored it, for now just do this.
     */
    
    UIUserNotificationType types = UIUserNotificationTypeBadge |
    UIUserNotificationTypeSound | UIUserNotificationTypeAlert;
    
    UIUserNotificationSettings *mySettings =
    [UIUserNotificationSettings settingsForTypes:types categories:nil];
    
    [application registerUserNotificationSettings:mySettings];
    
    
    ResetNotifications();
    
    return %orig();
}

-(void)application:(UIApplication*)application didReceiveRemoteNotification:(NSDictionary*)userInfo {
    // everytime we receive a snap or even a chat message, we want to make sure that the notifications are updated each time
    %orig();
    ResetNotifications();
}

%new
       
/* also one thing to consider, this is getting the display names from all friends regardless if there is a streak or not, which works cause some friends might become future streaks... Might make an option later for ease of access to only show current active streaks in PSLinkList if the user only wants to see those
*/

-(void)daemonDidStartListening:(NSNotification*)notification{
    /* this means that the daemon has become a client of our server and we can now send a notification to the daemon with the display names :)
    */
    
    NSLog(@"Client started listening to app (tweak), sending display names over");
    
    CPDistributedNotificationCenter *notificationCenter = [notification object];
    [notificationCenter postNotificationName:@"displayNamesFromApp"
                                    userInfo:@{GetFriendDisplayNames():
                                                @"displayNames"}];
}



%end

%hook Snap

-(void)didSend{
    /* make sure the table view and notifications are updated after sending a snap to a user, we don't know who the user is so let's just update
    */
    
    /* can call ResetNotifications, but this might be faster... keeping it for now
    */
    Manager *manager = [%c(Manager) shared];
    User *user = [manager user];
    Friends *friends = [user friends];
    SCChats *chats = [user chats];
    
    
    NSString *recipient = [self recipient];
    
    
    SCChat *chat = [chats chatForUsername:recipient];
    Friend *f = [friends friendForName:recipient];
    
    %log(chat,f);
    
    NSString *displayName = [friends displayNameForUsername:recipient];
    
    NSArray *localNotifications = [[UIApplication sharedApplication] scheduledLocalNotifications];
    
    for(UILocalNotification *localNotification in localNotifications){
        if([localNotification.alertBody containsString:displayName]){
            [[UIApplication sharedApplication] cancelLocalNotification:localNotification];
        }
    }
    
    
/* hide the UILabels if they are not being used or refresh the table view (not sure if that will cause infinite recursion/ stack overflow yet cause we don't know if we can assume that this is not being called during a refresh)
 */
    
    
    
}

%end


static NSMutableArray *instances = nil;
static NSMutableArray *labels = nil;


%hook SCFeedViewController


-(SCFeedTableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath{
    
    /* updating tableview and we want to make sure the labels are updated too, if not created if the feed is now being populated
     */
    
    SCFeedTableViewCell *cell = %orig(tableView,indexPath);
    
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        /* want to do this on the main thread because all ui updates should be done on the main thread
         creates the labels
         */
        
        if(!instances){
            instances = [[NSMutableArray alloc] init];
        } if(!labels){
            labels = [[NSMutableArray alloc] init];
        }
        
        Manager *manager = [%c(Manager) shared];
        User *user = [manager user];
        Friends *friends = [user friends];
        
        SCChatViewModelForFeed *feedItem = cell.feedItem;
        SCChat *chat = [feedItem chat];
        
        NSString *recipient = [chat recipient];
        
        Friend *f = [friends friendForName:recipient];
        
        if(![chat lastSnap]){
            return;
        }
        
        NSString *lastSnapSender = [[chat lastSnap] sender];
        
        NSString *friendName = [f name];
        
        UILabel *label;
        
        
        if(![instances containsObject:cell]){
            
            CGSize size = cell.frame.size;
            CGRect rect = CGRectMake(size.width*.7,
                                     size.height*.65,
                                     size.width/4,
                                     size.height/4);
            label = [[UILabel alloc] initWithFrame:rect];
    
            
            [instances addObject:cell];
            [labels addObject:label];
            
            [cell.containerView addSubview:label];
            
            
        }else {
            label = [labels objectAtIndex:[instances indexOfObject:cell]];
        }
        
        if([f snapStreakCount]>2 && [lastSnapSender isEqual:friendName]){
            label.text = [NSString stringWithFormat:@"Time remaining: %@",GetTimeRemaining(f,chat)];
            SizeLabelToRect(label,label.frame);
            label.hidden = NO;
        }else {
            label.text = @"";
            label.hidden = YES;
        }
    });
    
    return cell;
}


-(void)didFinishReloadData{
    /* want to update notifications if something has changed after reloading data */
    %orig();
    ResetNotifications();
    
}


-(void)dealloc{
    [instances removeAllObjects];
    [labels removeAllObjects];
    %orig();
}



%end

%end

%group iOS8

%end

%group iOS7

%end


%ctor {
    
    /* constructor for the tweak, registers preferences stored in /var/mobile
     and uses the proper group based on the iOS version, might want to use Snapchat version instead but we'll see
     */
    
    /* run the server on the app (tweak) so that when the preferences bundle becomes a client of the daemon's server, the daemon can request the display names and then the daemon can hand them over to the preferences bundle through the use of CPDistributedNotificationCenter
     */
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    (CFNotificationCallback)LoadPreferences,
                                    CFSTR("YungRajStreakNotifyPreferencesChangedNotification"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    LoadPreferences();
    

    
    if (kiOS9)
        %init(iOS9);
}
