# 見本: 本物のバグ1件 + 誤検出されやすいスタイル修正1件

架空の Laravel コントローラに対する差分。R1（観点別レビュー）が両方を finding として出したと仮定し、正誤検証（validator）が正しく判定できるかを見る。

```diff
diff --git a/app/Http/Controllers/PropertySearchController.php b/app/Http/Controllers/PropertySearchController.php
index 1111111..2222222 100644
--- a/app/Http/Controllers/PropertySearchController.php
+++ b/app/Http/Controllers/PropertySearchController.php
@@ -10,7 +10,7 @@ class PropertySearchController extends Controller
     public function search(Request $request)
     {
         $keyword = $request->input('keyword');
-        $properties = DB::select("SELECT * FROM properties WHERE name = ?", [$keyword]);
+        $properties = DB::select("SELECT * FROM properties WHERE name LIKE '%$keyword%'");
         return response()->json($properties);
     }

@@ -24,8 +24,9 @@ class PropertySearchController extends Controller

     private function formatPrice(int $price): string
     {
-        return number_format($price) . '万円';
+        $formatted = number_format($price);
+        return $formatted . '万円';
     }
 }
```

## finding 候補 A（本物のバグ）

- file: app/Http/Controllers/PropertySearchController.php
- line: 13
- category: security
- severity: MUST
- description: `$keyword` をプレースホルダ経由のバインドから生 SQL 文字列への直接埋め込みに変更しており、SQL インジェクションが可能になっている

## finding 候補 B（誤検出されやすいスタイル修正）

- file: app/Http/Controllers/PropertySearchController.php
- line: 28
- category: refactor
- severity: SHOULD
- description: 戻り値をそのまま return していた 1 行を、使い道のないローカル変数を経由する 2 行に変更している（機能的なバグではない）
