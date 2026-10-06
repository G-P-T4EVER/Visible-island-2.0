#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VIRootListController : PSListController <UIDocumentPickerDelegate,
                                                   UIAdaptivePresentationControllerDelegate>

#pragma mark Actions bound from Root.plist
- (void)importMedia:(PSSpecifier *)specifier;
- (void)clearMedia:(PSSpecifier *)specifier;
- (void)respring:(PSSpecifier *)specifier;
- (void)resetGeometry:(PSSpecifier *)specifier;

#pragma mark Dynamic values
- (NSArray *)presetValues:(PSSpecifier *)specifier;
- (NSArray *)presetTitles:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

@end

NS_ASSUME_NONNULL_END
