#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reusable blurred banner cell (used for the media status row and the
/// "About" group), matching the header treatment in VIRootListController.
@interface VIBlurHeaderCell : PSTableCell
@property (nonatomic, strong, readonly) UIVisualEffectView *blurView;
@end

NS_ASSUME_NONNULL_END
