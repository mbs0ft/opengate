#import <UIKit/UIKit.h>

@interface OpenGateManager : NSObject
@property (nonatomic, strong) NSString *selectedInstance;
@property (nonatomic, strong) NSArray *availableInstances;
+ (instancetype)sharedManager;
- (void)saveSelectedInstance:(NSString *)instance;
- (NSString *)getSelectedInstance;
@end

@interface InstanceSelectionViewController : UITableViewController
@property (nonatomic, strong) NSArray *instances;
@end

@implementation InstanceSelectionViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.instances = @[@"openvk.org", @"ovk.to", @"vk.lol"];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Выбор инстанса";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.instances.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    cell.textLabel.text = self.instances[indexPath.row];
    
    OpenGateManager *manager = [OpenGateManager sharedManager];
    if ([[manager getSelectedInstance] isEqualToString:self.instances[indexPath.row]]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    OpenGateManager *manager = [OpenGateManager sharedManager];
    [manager saveSelectedInstance:self.instances[indexPath.row]];
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [tableView reloadData];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Сохранено"
                                                                   message:@"Инстанс изменён. Перезапустите VK."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end