using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UI;
using CardboardXR.UI;

namespace iios.EditorTools
{
    // Adds a "SteamVR" button to CardboardXR's toolbar (Core.unity) and wires
    // it to the iios native bridge, which launches the FEX/Wine/DXMT SteamVR
    // backend and switches the view. Run headless:
    //   Unity -batchmode -quit -projectPath <cardboardxr> -buildTarget iOS \
    //     -executeMethod iios.EditorTools.AddSteamVrButton.Add
    public static class AddSteamVrButton
    {
        const string kScenePath = "Assets/_Project/Scenes/Core.unity";
        const string kItemName = "SteamVR";
        const string kItemIcon = "bolt";
        const string kItemLabel = "SteamVR";
        const float kItemWidth = 92f;

        [MenuItem("iios/Add SteamVR Toolbar Button")]
        public static void Add()
        {
            var scene = EditorSceneManager.OpenScene(kScenePath);
            var toolbar = Object.FindObjectOfType<M3Toolbar>(true);
            if (toolbar == null)
            {
                Debug.LogError("[iios] No M3Toolbar in " + kScenePath);
                return;
            }

            // Read the toolbar's serialized layout (fields are private).
            var so = new SerializedObject(toolbar);
            var itemsProp = so.FindProperty("m_Items");
            var groupsProp = so.FindProperty("m_Groups");
            var dividersProp = so.FindProperty("m_Dividers");
            var fullWidthProp = so.FindProperty("m_FullWidth");
            var itemWidthProp = so.FindProperty("m_ItemWidth");
            var paddingProp = so.FindProperty("m_Padding");
            var itemYProp = so.FindProperty("m_ItemY");

            var items = new List<RectTransform>();
            var groups = new List<int>();
            var dividers = new List<Image>();
            var fullWidth = new List<RectTransform>();
            for (var i = 0; i < itemsProp.arraySize; i++)
                items.Add(itemsProp.GetArrayElementAtIndex(i).objectReferenceValue as RectTransform);
            for (var i = 0; i < groupsProp.arraySize; i++)
                groups.Add(groupsProp.GetArrayElementAtIndex(i).intValue);
            for (var i = 0; i < dividersProp.arraySize; i++)
                dividers.Add(dividersProp.GetArrayElementAtIndex(i).objectReferenceValue as Image);
            for (var i = 0; i < fullWidthProp.arraySize; i++)
                fullWidth.Add(fullWidthProp.GetArrayElementAtIndex(i).objectReferenceValue as RectTransform);

            foreach (var existing in items)
            {
                if (existing != null && existing.name == kItemName)
                {
                    Debug.Log("[iios] SteamVR toolbar item already present.");
                    return;
                }
            }

            // Build the button with CardboardXR's own factory.
            var toolbarRect = toolbar.transform as RectTransform;
            var item = M3.ToolbarItem(kItemName, toolbarRect, kItemIcon, kItemLabel,
                Vector2.zero, kItemWidth, () => iios.IiosSteamVR.Toggle());
            var itemRect = item.transform as RectTransform;

            items.Add(itemRect);
            groups.Add(groups.Count == 0 ? 0 : groups[groups.Count - 1] + 1);
            dividers.Add(null); // divider before the new group; null = none

            // Write back and re-layout.
            itemsProp.arraySize = items.Count;
            for (var i = 0; i < items.Count; i++)
                itemsProp.GetArrayElementAtIndex(i).objectReferenceValue = items[i];
            groupsProp.arraySize = groups.Count;
            for (var i = 0; i < groups.Count; i++)
                groupsProp.GetArrayElementAtIndex(i).intValue = groups[i];
            dividersProp.arraySize = dividers.Count;
            for (var i = 0; i < dividers.Count; i++)
                dividersProp.GetArrayElementAtIndex(i).objectReferenceValue = dividers[i];
            so.ApplyModifiedPropertiesWithoutUndo();

            toolbar.Initialize(items.ToArray(), groups.ToArray(), dividers.ToArray(), fullWidth.ToArray(),
                itemWidthProp.floatValue, paddingProp.floatValue, itemYProp.floatValue);

            EditorUtility.SetDirty(toolbar);
            EditorSceneManager.MarkSceneDirty(scene);
            EditorSceneManager.SaveScene(scene);
            Debug.Log($"[iios] Added '{kItemName}' toolbar button to Core.unity");
        }
    }
}