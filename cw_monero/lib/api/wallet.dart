import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_monero/api/account_list.dart';
import 'package:cw_monero/api/exceptions/setup_wallet_exception.dart';
import 'package:cw_monero/api/wallet_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:monero/monero.dart' as monero;
import 'package:mutex/mutex.dart';
import 'package:polyseed/polyseed.dart';

bool debugMonero = false;

int getSyncingHeight() {
  // final height = monero.MONERO_cw_WalletListener_height(getWlptr());
  final h2 = monero.Wallet_blockChainHeight(wptr!);
  // printV("height: $height / $h2");
  return h2;
}

bool isNeededToRefresh() {
  final wlptr = getWlptr();
  if (wlptr == null) return false;
  final ret = monero.MONERO_cw_WalletListener_isNeedToRefresh(wlptr);
  monero.MONERO_cw_WalletListener_resetNeedToRefresh(wlptr);
  return ret;
}

bool isNewTransactionExist() {
  final wlptr = getWlptr();
  if (wlptr == null) return false;
  final ret = monero.MONERO_cw_WalletListener_isNewTransactionExist(wlptr);
  monero.MONERO_cw_WalletListener_resetIsNewTransactionExist(wlptr);
  return ret;
}

String getFilename() => monero.Wallet_filename(wptr!);

String getSeed() {
  // monero.Wallet_setCacheAttribute(wptr!, key: "cakewallet.seed", value: seed);
  final cakepolyseed =
      monero.Wallet_getCacheAttribute(wptr!, key: "cakewallet.seed");
  final cakepassphrase = getPassphrase();

  final weirdPolyseed = monero.Wallet_getPolyseed(wptr!, passphrase: cakepassphrase);
  if (weirdPolyseed != "") return weirdPolyseed;

  if (cakepolyseed != "") {
    if (cakepassphrase != "") {
      try {
        final lang = PolyseedLang.getByPhrase(cakepolyseed);
        final coin = PolyseedCoin.POLYSEED_MONERO;
        final ps = Polyseed.decode(cakepolyseed, lang, coin);
        if (ps.isEncrypted || cakepassphrase == "") return ps.encode(lang, coin);
        ps.crypt(cakepassphrase);
        return ps.encode(lang, coin);
      } catch (e) {
        printV(e);
      }
    }
    return cakepolyseed;
  }

  final bip39 = monero.Wallet_getCacheAttribute(wptr!, key: "cakewallet.seed.bip39");

  if(bip39.isNotEmpty) return bip39;

  final legacy = getSeedLegacy(null);
  return legacy;
}

String? getSeedLanguage(String? language) {
  switch (language) {
    case "Chinese (Traditional)": language = "Chinese (simplified)"; break;
    case "Chinese (Simplified)": language = "Chinese (simplified)"; break;
    case "Korean": language = "English"; break;
    case "Czech": language = "English"; break;
    case "Japanese": language = "English"; break;
  }
  return language;
}

String getSeedLegacy(String? language) {
  final cakepassphrase = getPassphrase();
  language = getSeedLanguage(language);
  var legacy = monero.Wallet_seed(wptr!, seedOffset: cakepassphrase);
  if (monero.Wallet_status(wptr!) != 0) {
    if (monero.Wallet_errorString(wptr!).contains("seed_language")) {
      monero.Wallet_setSeedLanguage(wptr!, language: "English");
      legacy = monero.Wallet_seed(wptr!, seedOffset: cakepassphrase);
    }
  }

  if (language != null) {
    monero.Wallet_setSeedLanguage(wptr!, language: language);
    final status = monero.Wallet_status(wptr!);
    if (status != 0) {
      final err = monero.Wallet_errorString(wptr!);
      if (legacy.isNotEmpty) {
        return "$err\n\n$legacy";
      }
      return err;
    }
    legacy = monero.Wallet_seed(wptr!, seedOffset: cakepassphrase);
  }

  if (monero.Wallet_status(wptr!) != 0) {
    final err = monero.Wallet_errorString(wptr!);
    if (legacy.isNotEmpty) {
      return "$err\n\n$legacy";
    }
    return err;
  }
  return legacy;
}

String getPassphrase() {
  return monero.Wallet_getCacheAttribute(wptr!, key: "cakewallet.passphrase");
}

Map<int, Map<int, Map<int, String>>> addressCache = {};

String getAddress({int accountIndex = 0, int addressIndex = 0}) {
  // printV("getaddress: ${accountIndex}/${addressIndex}: ${monero.Wallet_numSubaddresses(wptr!, accountIndex: accountIndex)}: ${monero.Wallet_address(wptr!, accountIndex: accountIndex, addressIndex: addressIndex)}");
  // this could be a while loop, but I'm in favor of making it if to not cause freezes
  if (monero.Wallet_numSubaddresses(wptr!, accountIndex: accountIndex)-1 < addressIndex) {
    if (monero.Wallet_numSubaddressAccounts(wptr!) < accountIndex) {
      monero.Wallet_addSubaddressAccount(wptr!);
    } else {
      monero.Wallet_addSubaddress(wptr!, accountIndex: accountIndex);
    }
  }
  addressCache[wptr!.address] ??= {};
  addressCache[wptr!.address]![accountIndex] ??= {};
  addressCache[wptr!.address]![accountIndex]![addressIndex] ??= monero.Wallet_address(wptr!,
        accountIndex: accountIndex, addressIndex: addressIndex);
  return addressCache[wptr!.address]![accountIndex]![addressIndex]!;
}

int getFullBalance({int accountIndex = 0}) =>
    monero.Wallet_balance(wptr!, accountIndex: accountIndex);

int getUnlockedBalance({int accountIndex = 0}) =>
    monero.Wallet_unlockedBalance(wptr!, accountIndex: accountIndex);

int getCurrentHeight() => monero.Wallet_blockChainHeight(wptr!);

int getNodeHeightSync() => monero.Wallet_daemonBlockChainHeight(wptr!);

bool isConnectedSync() => monero.Wallet_connected(wptr!) != 0;

Future<bool> setupNodeSync(
    {required String address,
    String? login,
    String? password,
    bool useSSL = false,
    bool isLightWallet = false,
    String? socksProxyAddress}) async {
  printV('''
{
  wptr!,
  daemonAddress: $address,
  useSsl: $useSSL,
  proxyAddress: $socksProxyAddress ?? '',
  daemonUsername: $login ?? '',
  daemonPassword: $password ?? ''
}
''');
  final addr = wptr!.address;
  printV("init: start");
  await Isolate.run(() {
    monero.Wallet_init(Pointer.fromAddress(addr),
        daemonAddress: address,
        useSsl: useSSL,
        proxyAddress: socksProxyAddress ?? '',
        daemonUsername: login ?? '',
        daemonPassword: password ?? '');
  });
  printV("init: end");

  final status = monero.Wallet_status(wptr!);

  if (status != 0) {
    final error = monero.Wallet_errorString(wptr!);
    if (error != "no tx keys found for this txid") {
      printV("error: $error");
      throw SetupWalletException(message: error);
    }
  }

  if (true) {
    monero.Wallet_init3(
      wptr!, argv0: '',
      defaultLogBaseName: 'moneroc',
      console: true,
      logPath: '',
    );
  }

  return status == 0;
}

void startRefreshSync() {
  monero.Wallet_refreshAsync(wptr!);
  monero.Wallet_startRefresh(wptr!);
}


void setRefreshFromBlockHeight({required int height}) {
  monero.Wallet_setRefreshFromBlockHeight(wptr!,
    refresh_from_block_height: height);
}

void setRecoveringFromSeed({required bool isRecovery}) {
  monero.Wallet_setRecoveringFromSeed(wptr!, recoveringFromSeed: isRecovery);
  monero.Wallet_store(wptr!);
}

final storeMutex = Mutex();


int lastStorePointer = 0;
int lastStoreHeight = 0;
void storeSync({bool force = false}) async {
  final addr = wptr!.address;
  final synchronized = await Isolate.run(() {
    return monero.Wallet_synchronized(Pointer.fromAddress(addr));
  });
  if (lastStorePointer == wptr!.address &&
      lastStoreHeight + 5000 > monero.Wallet_blockChainHeight(wptr!) &&
      !synchronized && 
      !force) {
    return;
  }
  lastStorePointer = wptr!.address;
  lastStoreHeight = monero.Wallet_blockChainHeight(wptr!);
  await storeMutex.acquire();
  await Isolate.run(() {
    monero.Wallet_store(Pointer.fromAddress(addr));
  });
  storeMutex.release();
}

void setPasswordSync(String password) {
  monero.Wallet_setPassword(wptr!, password: password);

  final status = monero.Wallet_status(wptr!);
  if (status != 0) {
    throw Exception(monero.Wallet_errorString(wptr!));
  }
}

void closeCurrentWallet() {
  monero.Wallet_stop(wptr!);
}

String getSecretViewKey() => monero.Wallet_secretViewKey(wptr!);

String getPublicViewKey() => monero.Wallet_publicViewKey(wptr!);

String getSecretSpendKey() => monero.Wallet_secretSpendKey(wptr!);

String getPublicSpendKey() => monero.Wallet_publicSpendKey(wptr!);

class SyncListener {
  SyncListener(this.onNewBlock, this.onNewTransaction)
      : _cachedBlockchainHeight = 0,
        _lastKnownBlockHeight = 0,
        _initialSyncHeight = 0 {
          _start();
        }

  void Function(int, int, double) onNewBlock;
  void Function() onNewTransaction;

  Timer? _updateSyncInfoTimer;
  int _cachedBlockchainHeight;
  int _lastKnownBlockHeight;
  int _initialSyncHeight;

  Future<int> getNodeHeightOrUpdate(int baseHeight) async {
    if (_cachedBlockchainHeight < baseHeight || _cachedBlockchainHeight == 0) {
      _cachedBlockchainHeight = await getNodeHeight();
    }

    return _cachedBlockchainHeight;
  }

  void _start() {
    _cachedBlockchainHeight = 0;
    _lastKnownBlockHeight = 0;
    _initialSyncHeight = 0;
    _updateSyncInfoTimer ??=
        Timer.periodic(Duration(milliseconds: 1200), (_) async {
      if (isNewTransactionExist()) {
        onNewTransaction();
      }

      var syncHeight = getSyncingHeight();

      if (syncHeight <= 0) {
        syncHeight = getCurrentHeight();
      }

      if (_initialSyncHeight <= 0) {
        _initialSyncHeight = syncHeight;
      }

      final bchHeight = await getNodeHeightOrUpdate(syncHeight);
      // printV("syncHeight: $syncHeight, _lastKnownBlockHeight: $_lastKnownBlockHeight, bchHeight: $bchHeight");
      if (_lastKnownBlockHeight == syncHeight) {
        return;
      }

      _lastKnownBlockHeight = syncHeight;
      final track = bchHeight - _initialSyncHeight;
      final diff = track - (bchHeight - syncHeight);
      final ptc = diff <= 0 ? 0.0 : diff / track;
      final left = bchHeight - syncHeight;

      if (syncHeight < 0 || left < 0) {
        return;
      }

      // 1. Actual new height; 2. Blocks left to finish; 3. Progress in percents;
      onNewBlock.call(syncHeight, left, ptc);
    });
  }

  void stop() => _updateSyncInfoTimer?.cancel();
}

SyncListener setListeners(void Function(int, int, double) onNewBlock,
    void Function() onNewTransaction) {
  final listener = SyncListener(onNewBlock, onNewTransaction);
  // setListenerNative();
  return listener;
}

void onStartup() {}

void _storeSync(Object _) => storeSync();

Future<bool> _setupNodeSync(Map<String, Object?> args) async {
  final address = args['address'] as String;
  final login = (args['login'] ?? '') as String;
  final password = (args['password'] ?? '') as String;
  final useSSL = args['useSSL'] as bool;
  final isLightWallet = args['isLightWallet'] as bool;
  final socksProxyAddress = (args['socksProxyAddress'] ?? '') as String;

  return setupNodeSync(
      address: address,
      login: login,
      password: password,
      useSSL: useSSL,
      isLightWallet: isLightWallet,
      socksProxyAddress: socksProxyAddress);
}

bool _isConnected(Object _) => isConnectedSync();

int _getNodeHeight(Object _) => getNodeHeightSync();

void startRefresh() => startRefreshSync();

Future<void> setupNode(
        {required String address,
        String? login,
        String? password,
        bool useSSL = false,
        String? socksProxyAddress,
        bool isLightWallet = false}) async =>
    _setupNodeSync({
      'address': address,
      'login': login,
      'password': password,
      'useSSL': useSSL,
      'isLightWallet': isLightWallet,
      'socksProxyAddress': socksProxyAddress
    });

Future<void> store() async => _storeSync(0);

Future<bool> isConnected() async => _isConnected(0);

Future<int> getNodeHeight() async => _getNodeHeight(0);

void rescanBlockchainAsync() => monero.Wallet_rescanBlockchainAsync(wptr!);

String getSubaddressLabel(int accountIndex, int addressIndex) {
  return monero.Wallet_getSubaddressLabel(wptr!,
      accountIndex: accountIndex, addressIndex: addressIndex);
}

Future setTrustedDaemon(bool trusted) async =>
    monero.Wallet_setTrustedDaemon(wptr!, arg: trusted);

Future<bool> trustedDaemon() async => monero.Wallet_trustedDaemon(wptr!);

String signMessage(String message, {String address = ""}) {
  return monero.Wallet_signMessage(wptr!, message: message, address: address);
}

bool verifyMessage(String message, String address, String signature) {
  return monero.Wallet_verifySignedMessage(wptr!, message: message, address: address, signature: signature);
}

Map<String, List<int>> debugCallLength() => monero.debugCallLength;
